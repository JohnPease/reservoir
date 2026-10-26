import XCTest
import SwiftData
@testable import Reservoir

final class BudgetCalculatorTests: XCTestCase {

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        let schema = Schema(versionedSchema: SchemaV9.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, migrationPlan: ReservoirMigrationPlan.self, configurations: [configuration])
        context = ModelContext(container)
    }

    override func tearDownWithError() throws {
        context = nil
        container = nil
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    @discardableResult
    private func txn(
        _ amount: Decimal,
        on day: Date,
        account: String? = "acct-1",
        type: TransactionType = .variable,
        method: EntryMethod = .imported,
        goal: SavingsGoal? = nil
    ) -> SpendTransaction {
        let transaction = SpendTransaction(
            amount: amount, date: day, merchantName: "M", type: type, entryMethod: method,
            plaidAccountID: account, savingsGoal: goal
        )
        context.insert(transaction)
        return transaction
    }

    private func makeBudget(
        monthly: Decimal = 3100,
        start: Date,
        carries: Bool = true,
        accounts: [String] = ["acct-1"]
    ) -> Budget {
        let budget = Budget(monthlyAmount: monthly, startDate: start, carriesAcrossMonths: carries, selectedAccountIDs: accounts)
        context.insert(budget)
        return budget
    }

    private func all() throws -> [SpendTransaction] { try context.fetch(FetchDescriptor<SpendTransaction>()) }

    // MARK: - Predicate

    func testPredicateCountsOnlySelectedAccountVariableOnOrAfterStart() throws {
        let start = date(2026, 1, 5)
        let selected: Set<String> = ["acct-1"]
        func counts(_ t: SpendTransaction) -> Bool {
            BudgetCalculator.countsTowardBudget(t, selectedAccountIDs: selected, startDate: start, calendar: calendar)
        }
        XCTAssertTrue(counts(txn(10, on: date(2026, 1, 5))))
        XCTAssertFalse(counts(txn(10, on: date(2026, 1, 4))), "before start date")
        XCTAssertFalse(counts(txn(10, on: date(2026, 1, 6), account: "acct-2")), "unselected account")
        XCTAssertFalse(counts(txn(10, on: date(2026, 1, 6), account: nil)), "nil account")
        XCTAssertFalse(counts(txn(10, on: date(2026, 1, 6), account: nil, method: .manual)), "manual row")
        XCTAssertFalse(counts(txn(10, on: date(2026, 1, 6), type: .fixed)), "fixed excluded")
    }

    func testSummaryHonorsFiltersAndComputesSpentAndRemaining() throws {
        let budget = makeBudget(start: date(2026, 1, 1))
        txn(30, on: date(2026, 1, 2))                      // counts
        txn(500, on: date(2026, 1, 2), account: "other")   // ignored
        txn(500, on: date(2026, 1, 2), account: nil, method: .manual)
        txn(500, on: date(2026, 1, 2), type: .fixed)
        txn(25, on: date(2026, 1, 4))                      // today
        let summary = try XCTUnwrap(BudgetCalculator.summary(
            budget: budget, allTransactions: try all(), referenceDate: date(2026, 1, 4), calendar: calendar
        ))
        XCTAssertEqual(summary.dailyBase, 100)
        XCTAssertEqual(summary.carriedForward, 300 - 30)   // Jan 1, 2, 3
        XCTAssertEqual(summary.limit, 370)
        XCTAssertEqual(summary.spentToday, 25)
        XCTAssertEqual(summary.remaining, 345)
    }

    func testSummaryIsNilWithoutBudget() throws {
        XCTAssertNil(BudgetCalculator.summary(budget: nil, allTransactions: [], referenceDate: date(2026, 1, 4), calendar: calendar))
    }

    func testMidMonthStartOnFirstWithTodayThe18th() throws {
        let budget = makeBudget(start: date(2026, 1, 1))
        let summary = try XCTUnwrap(BudgetCalculator.summary(
            budget: budget, allTransactions: [], referenceDate: date(2026, 1, 18), calendar: calendar
        ))
        XCTAssertEqual(summary.carriedForward, 1700)
    }

    func testStartDateInPriorMonthCarryAccumulatesAcrossMonthsResetOnlyCurrentMonth() throws {
        let carry = makeBudget(monthly: 2800, start: date(2026, 2, 20), carries: true)
        let reset = makeBudget(monthly: 2800, start: date(2026, 2, 20), carries: false)
        let carrySummary = try XCTUnwrap(BudgetCalculator.summary(budget: carry, allTransactions: [], referenceDate: date(2026, 3, 10), calendar: calendar))
        let resetSummary = try XCTUnwrap(BudgetCalculator.summary(budget: reset, allTransactions: [], referenceDate: date(2026, 3, 10), calendar: calendar))
        XCTAssertEqual(carrySummary.carriedForward, 900 + resetSummary.carriedForward)
        XCTAssertGreaterThan(resetSummary.carriedForward, 0)
    }

    func testNoCreatedAtFloorOnEffectiveStartDate() throws {
        let budget = Budget(monthlyAmount: 3100, startDate: date(2026, 1, 1), selectedAccountIDs: ["acct-1"], createdAt: date(2026, 1, 20))
        context.insert(budget)
        let input = BudgetCalculator.carryForwardInput(for: budget, transactions: [], calendar: calendar)
        XCTAssertEqual(input.effectiveStartDate, date(2026, 1, 1))
        XCTAssertEqual(input.monthBoundary, .carry)
        XCTAssertEqual(input.schedule, .monthly(3100))
    }

    // MARK: - Edit recompute

    func testEditingSettingsRecomputesWholeWindowFromCurrentFields() throws {
        let budget = makeBudget(monthly: 3100, start: date(2026, 1, 1), carries: true)
        txn(1000, on: date(2026, 1, 10))
        txn(200, on: date(2026, 2, 3), account: "acct-2")
        let transactions = try all()
        let ref = date(2026, 2, 5)

        let before = try XCTUnwrap(BudgetCalculator.summary(budget: budget, allTransactions: transactions, referenceDate: ref, calendar: calendar))

        budget.carriesAcrossMonths = false
        let reset = try XCTUnwrap(BudgetCalculator.summary(budget: budget, allTransactions: transactions, referenceDate: ref, calendar: calendar))
        XCTAssertNotEqual(before.carriedForward, reset.carriedForward)

        budget.carriesAcrossMonths = true
        budget.selectedAccountIDs = ["acct-1", "acct-2"]
        let widened = try XCTUnwrap(BudgetCalculator.summary(budget: budget, allTransactions: transactions, referenceDate: ref, calendar: calendar))
        XCTAssertEqual(before.carriedForward - widened.carriedForward, 200)

        budget.selectedAccountIDs = ["acct-1"]
        budget.startDate = date(2026, 1, 11)    // excludes the 1000 txn and 10 days
        let later = try XCTUnwrap(BudgetCalculator.summary(budget: budget, allTransactions: transactions, referenceDate: ref, calendar: calendar))
        // Dropping Jan 1-10 removes 10 days of base (1000) and the 1000 spend: net zero.
        XCTAssertEqual(later.carriedForward, before.carriedForward)
    }

    // MARK: - Independence from goals

    func testSameTransactionCountsTowardGoalAndBudgetIndependently() throws {
        let goal = SavingsGoal(
            targetAmount: 1000, targetDate: date(2026, 2, 1), startDate: date(2026, 1, 1),
            startingBalance: 0, dailyBase: 10, createdAt: date(2026, 1, 1), associatedItemIDs: ["item-1"]
        )
        context.insert(goal)
        let shared = txn(40, on: date(2026, 1, 3), goal: goal)
        let budget = makeBudget(start: date(2026, 1, 1))
        let ref = date(2026, 1, 4)

        let goalSummary = try XCTUnwrap(TodayScreenCalculator.summary(
            activeGoals: [goal], allTransactions: try all(), referenceDate: ref, calendar: calendar
        ))
        let budgetSummary = try XCTUnwrap(BudgetCalculator.summary(budget: budget, allTransactions: try all(), referenceDate: ref, calendar: calendar))

        XCTAssertEqual(goalSummary.carriedForward, 3 * 10 - 40)
        _ = shared
        XCTAssertEqual(budgetSummary.carriedForward, 300 - 40)
    }

    func testBudgetSelectionNeverTouchesGoalAssociations() throws {
        let goal = SavingsGoal(
            targetAmount: 1000, targetDate: date(2026, 2, 1), startDate: date(2026, 1, 1),
            startingBalance: 0, dailyBase: 10, associatedItemIDs: ["item-1"]
        )
        context.insert(goal)
        try context.save()

        XCTAssertNil(BudgetService.save(monthlyAmount: 1000, startDate: date(2026, 1, 1), carriesAcrossMonths: true, selectedAccountIDs: ["acct-1", "acct-9"], modelContext: context))
        XCTAssertEqual(goal.associatedItemIDs, ["item-1"])

        let store = StubLinkedAccountStore()
        store.upsert([LinkedAccount(accountID: "acct-1", itemID: "item-1", name: "Chk", type: "depository")])
        BudgetAccountService.prune(itemID: "item-1", linkedAccountStore: store, modelContext: context)
        XCTAssertEqual(goal.associatedItemIDs, ["item-1"])
    }

    // MARK: - Card state

    func testCardStateGatingOrder() {
        let withAccounts = Budget(monthlyAmount: 100, startDate: .now, selectedAccountIDs: ["a"])
        let empty = Budget(monthlyAmount: 100, startDate: .now, selectedAccountIDs: [])
        XCTAssertEqual(BudgetCalculator.cardState(for: withAccounts, isAccountBackfillComplete: false), .syncing)
        XCTAssertEqual(BudgetCalculator.cardState(for: empty, isAccountBackfillComplete: false), .syncing)
        XCTAssertEqual(BudgetCalculator.cardState(for: empty, isAccountBackfillComplete: true), .chooseAccounts)
        XCTAssertEqual(BudgetCalculator.cardState(for: withAccounts, isAccountBackfillComplete: true), .active)
        XCTAssertEqual(BudgetCalculator.CardState.syncing.message, "Syncing account data...")
        XCTAssertEqual(BudgetCalculator.CardState.chooseAccounts.message, "Choose accounts")
        XCTAssertNil(BudgetCalculator.CardState.active.message)
    }

    func testCardModelOnlyComputesFiguresWhenActive() throws {
        XCTAssertNil(BudgetCalculator.cardModel(budget: nil, allTransactions: [], isAccountBackfillComplete: true, referenceDate: date(2026, 1, 4), calendar: calendar))

        let budget = makeBudget(start: date(2026, 1, 1))
        let syncing = BudgetCalculator.cardModel(budget: budget, allTransactions: [], isAccountBackfillComplete: false, referenceDate: date(2026, 1, 4), calendar: calendar)
        XCTAssertEqual(syncing, .init(state: .syncing, summary: nil))

        budget.selectedAccountIDs = []
        let empty = BudgetCalculator.cardModel(budget: budget, allTransactions: [], isAccountBackfillComplete: true, referenceDate: date(2026, 1, 4), calendar: calendar)
        XCTAssertEqual(empty, .init(state: .chooseAccounts, summary: nil))

        budget.selectedAccountIDs = ["acct-1"]
        let active = BudgetCalculator.cardModel(budget: budget, allTransactions: [], isAccountBackfillComplete: true, referenceDate: date(2026, 1, 4), calendar: calendar)
        XCTAssertEqual(active?.state, .active)
        XCTAssertEqual(active?.summary?.carriedForward, 300)
    }

    // MARK: - Performance sanity

    func testSummaryOver730DayWindowWithManyTransactionsIsFast() throws {
        let start = date(2024, 10, 26)
        let budget = makeBudget(monthly: 3000, start: start, carries: false)
        for offset in 0..<730 {
            let day = calendar.date(byAdding: .day, value: offset, to: start)!
            txn(Decimal(offset % 50), on: day)
            txn(5, on: day, account: "other")
        }
        let transactions = try all()
        let ref = date(2026, 10, 26)
        let began = Date()
        for _ in 0..<5 {
            _ = BudgetCalculator.summary(budget: budget, allTransactions: transactions, referenceDate: ref, calendar: calendar)
        }
        let perCall = Date().timeIntervalSince(began) / 5
        XCTAssertLessThan(perCall, 0.5, "730-day recompute should be well under half a second")
    }
}
