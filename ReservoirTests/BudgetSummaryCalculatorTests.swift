import XCTest
import SwiftData
@testable import Reservoir

final class BudgetSummaryCalculatorTests: XCTestCase {

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        let schema = Schema(versionedSchema: SchemaV11.self)
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

    private func txn(_ amount: Decimal, _ day: Date, account: String? = "a1", item: String? = "item-1", type: TransactionType = .variable) -> SpendTransaction {
        let transaction = SpendTransaction(
            amount: amount, date: day, merchantName: "M", type: type, entryMethod: .imported,
            plaidItemID: item, plaidAccountID: account
        )
        context.insert(transaction)
        return transaction
    }

    private func budget(monthly: Decimal = 3100, start: Date, carries: Bool = true, accounts: [String] = ["a1"]) -> Budget {
        let budget = Budget(monthlyAmount: monthly, startDate: start, carriesAcrossMonths: carries, selectedAccountIDs: accounts)
        context.insert(budget)
        return budget
    }

    private func account(_ id: String, name: String = "Checking", mask: String? = "0001", item: String = "item-1") -> LinkedAccount {
        LinkedAccount(accountID: id, itemID: item, name: name, mask: mask, type: "depository")
    }

    private func insights(
        _ budget: Budget?, _ transactions: [SpendTransaction] = [], on day: Date,
        backfill: Bool = true, accounts: [LinkedAccount] = [], items: [LinkedItem] = []
    ) -> BudgetSummaryCalculator.BudgetInsights? {
        BudgetSummaryCalculator.insights(
            budget: budget, transactions: transactions, isAccountBackfillComplete: backfill,
            referenceDate: day, linkedAccounts: accounts, linkedItems: items, calendar: calendar
        )
    }

    // MARK: - Sentence

    // $3100 / 31 days = $100 per day in October.
    func testUnderPace() throws {
        let b = budget(start: date(2026, 9, 1))
        let t = [txn(300, date(2026, 10, 3))]
        let result = try XCTUnwrap(insights(b, t, on: date(2026, 10, 4)))
        // 4 days budgeted = 400, spent 300
        XCTAssertEqual(result.sentence.text, "Day 4 of 31. You've spent $300, about $100 under pace.")
        XCTAssertNil(result.sentence.deficitPhrase)
    }

    func testOverPaceHighlightsOnlyThePhrase() throws {
        let b = budget(start: date(2026, 9, 1))
        let t = [txn(560, date(2026, 10, 3))]
        let result = try XCTUnwrap(insights(b, t, on: date(2026, 10, 4)))
        XCTAssertEqual(result.sentence.text, "Day 4 of 31. You've spent $560, about $160 over pace.")
        XCTAssertEqual(result.sentence.deficitPhrase, "about $160 over pace")
        XCTAssertEqual(result.sentence.lead, "Day 4 of 31. You've spent $560, ")
        XCTAssertEqual(result.sentence.tail, ".")
    }

    func testRightOnPaceWithinOneDollar() throws {
        let b = budget(start: date(2026, 9, 1))
        let t = [txn(399.50, date(2026, 10, 2))]
        let result = try XCTUnwrap(insights(b, t, on: date(2026, 10, 4)))
        XCTAssertEqual(result.sentence.text, "Day 4 of 31. You've spent $400, right on pace.")
    }

    func testDayOneNoSpendOnMidMonthStartAndFirst() throws {
        let b = budget(start: date(2026, 9, 1), carries: false)
        let result = try XCTUnwrap(insights(b, [], on: date(2026, 10, 1)))
        XCTAssertEqual(result.sentence.text, "Day 1 of 31. No spending yet this month. Fresh month, nothing carried over.")

        let mid = budget(start: date(2026, 10, 14))
        let midResult = try XCTUnwrap(insights(mid, [], on: date(2026, 10, 14)))
        XCTAssertEqual(midResult.sentence.text, "Day 14 of 31 (tracking since Oct 14). No spending yet this month.")
    }

    func testFirstOfMonthWithSpendUsesNormalSentence() throws {
        let b = budget(start: date(2026, 10, 1))
        let t = [txn(20, date(2026, 10, 1))]
        let result = try XCTUnwrap(insights(b, t, on: date(2026, 10, 1)))
        XCTAssertEqual(result.sentence.text, "Day 1 of 31. You've spent $20, about $80 under pace.")
    }

    func testMidMonthStartUsesShorterWindow() throws {
        let b = budget(start: date(2026, 10, 12))
        let t = [txn(250, date(2026, 10, 13))]
        let result = try XCTUnwrap(insights(b, t, on: date(2026, 10, 14)))
        XCTAssertEqual(result.trackingSince, date(2026, 10, 12))
        // 3 days budgeted (12,13,14) = 300
        XCTAssertEqual(result.budgetedToDate, 300)
        XCTAssertEqual(result.sentence.text, "Day 14 of 31 (tracking since Oct 12). You've spent $250, about $50 under pace.")
    }

    func testTransactionsBeforeStartAreNotCounted() throws {
        let b = budget(start: date(2026, 10, 12))
        let t = [txn(900, date(2026, 10, 5)), txn(10, date(2026, 10, 12))]
        let result = try XCTUnwrap(insights(b, t, on: date(2026, 10, 12)))
        XCTAssertEqual(result.spent, 10)
    }

    func testOverBudgetForMonthReplacesPaceSentence() throws {
        let b = budget(monthly: 3000, start: date(2026, 9, 1))
        let t = [txn(3150, date(2026, 10, 10))]
        let result = try XCTUnwrap(insights(b, t, on: date(2026, 10, 22)))
        XCTAssertEqual(result.sentence.text, "Day 22 of 31. You've spent $3,150 of your $3,000 budget, $150 over for the month.")
        XCTAssertEqual(result.sentence.deficitPhrase, "$150 over for the month")
    }

    func testFewCentsOverBudgetReadsAsPaceNotZeroDollarsOver() throws {
        let b = budget(monthly: 3100, start: date(2026, 10, 1))
        let spend = txn(Decimal(string: "3100.40")!, date(2026, 10, 20))
        let result = try XCTUnwrap(insights(b, [spend], on: date(2026, 10, 31)))
        XCTAssertFalse(result.sentence.text.contains("over for the month"))
        XCTAssertFalse(result.sentence.text.contains("$0 over"))
        XCTAssertTrue(result.sentence.text.contains("right on pace"), result.sentence.text)
    }

    func testOverBudgetByAtLeastOneDollarShowsOverForTheMonth() throws {
        let b = budget(monthly: 3100, start: date(2026, 10, 1))
        let spend = txn(3101, date(2026, 10, 20))
        let result = try XCTUnwrap(insights(b, [spend], on: date(2026, 10, 31)))
        XCTAssertEqual(result.sentence.deficitPhrase, "$1 over for the month")
    }

    func testMidMonthStartOverBudgetComparesAgainstProratedWindowBudget() throws {
        // Start Oct 12: window Oct 12..31 = 20 days = $2,000 of the $3,100 monthly amount.
        // $2,500 is under the full amount but over the prorated one.
        let b = budget(monthly: 3100, start: date(2026, 10, 12))
        let t = [txn(2500, date(2026, 10, 13))]
        let result = try XCTUnwrap(insights(b, t, on: date(2026, 10, 14)))
        XCTAssertEqual(
            result.sentence.text,
            "Day 14 of 31 (tracking since Oct 12). You've spent $2,500 of your $2,000 budget for this period, $500 over."
        )
        XCTAssertEqual(result.sentence.deficitPhrase, "$500 over")
    }

    func testMidMonthStartUnderProratedBudgetKeepsPaceSentence() throws {
        let b = budget(monthly: 3100, start: date(2026, 10, 12))
        let t = [txn(1999, date(2026, 10, 13))]
        let result = try XCTUnwrap(insights(b, t, on: date(2026, 10, 14)))
        XCTAssertFalse(result.sentence.text.contains("budget for this period"))
    }

    func testMidMonthStartOverSentenceAndProjectionAgree() throws {
        // Window budget $2,200 (start Oct 10). Spending $2,300 by Oct 17 is over the window
        // budget: the sentence and the projection must both say over.
        let b = budget(monthly: 3100, start: date(2026, 10, 10))
        let t = [txn(2300, date(2026, 10, 11))]
        let result = try XCTUnwrap(insights(b, t, on: date(2026, 10, 17)))
        XCTAssertEqual(result.sentence.deficitPhrase, "$100 over")
        XCTAssertEqual(result.projection?.windowBudget, 2200)
        XCTAssertTrue(try XCTUnwrap(result.projection).projectedDelta < 0)
    }

    func testMidMonthStartOverByLessThanADollarIsNotOver() throws {
        let b = budget(monthly: 3100, start: date(2026, 10, 12))
        let t = [txn(Decimal(string: "2000.50")!, date(2026, 10, 13))]
        let result = try XCTUnwrap(insights(b, t, on: date(2026, 10, 14)))
        XCTAssertFalse(result.sentence.text.contains("budget for this period"))
    }

    func testFirstOfMonthCarryClauses() throws {
        // September: base 100/day (3000/30), spend nothing => carry in = +3000.
        let b = budget(monthly: 3000, start: date(2026, 9, 1))
        let carried = try XCTUnwrap(insights(b, [], on: date(2026, 10, 1)))
        XCTAssertEqual(carried.sentence.text, "Day 1 of 31. No spending yet this month. $3,000 carried over from last month.")

        // Overspend September by 500 => in the hole 500.
        let hole = [txn(3500, date(2026, 9, 10))]
        let holeResult = try XCTUnwrap(insights(b, hole, on: date(2026, 10, 1)))
        XCTAssertEqual(holeResult.sentence.text, "Day 1 of 31. No spending yet this month. Starting $500 in the hole from last month.")
    }

    func testFirstOfMonthZeroCarryOmitsClauseAndResetModeAlwaysFresh() throws {
        let zero = budget(monthly: 3000, start: date(2026, 9, 1))
        let exact = [txn(3000, date(2026, 9, 10))]
        let result = try XCTUnwrap(insights(zero, exact, on: date(2026, 10, 1)))
        XCTAssertEqual(result.sentence.text, "Day 1 of 31. No spending yet this month.")

        let reset = budget(monthly: 3000, start: date(2026, 9, 1), carries: false)
        let resetResult = try XCTUnwrap(insights(reset, [], on: date(2026, 10, 1)))
        XCTAssertTrue(resetResult.sentence.text.hasSuffix("Fresh month, nothing carried over."))
    }

    func testNoClauseAfterTheFirst() throws {
        let b = budget(start: date(2026, 9, 1), carries: false)
        let result = try XCTUnwrap(insights(b, [], on: date(2026, 10, 2)))
        XCTAssertFalse(result.sentence.text.contains("Fresh month"))
    }

    // MARK: - Pace math: month-local, identical in carry and reset mode

    func testPaceIdenticalInCarryAndResetMode() throws {
        let t = [txn(250, date(2026, 10, 3)), txn(900, date(2026, 9, 20))]
        let carry = try XCTUnwrap(insights(budget(start: date(2026, 9, 1), carries: true), t, on: date(2026, 10, 5)))
        let reset = try XCTUnwrap(insights(budget(start: date(2026, 9, 1), carries: false), t, on: date(2026, 10, 5)))
        XCTAssertEqual(carry.paceDelta, 250)
        XCTAssertEqual(carry.paceDelta, reset.paceDelta)
        XCTAssertEqual(carry.spent, reset.spent)
        XCTAssertEqual(carry.sentence, reset.sentence)
    }

    func testFixedAndUnselectedAccountSpendIgnored() throws {
        let b = budget(start: date(2026, 9, 1))
        let t = [txn(50, date(2026, 10, 2), type: .fixed), txn(70, date(2026, 10, 2), account: "other"), txn(30, date(2026, 10, 2))]
        XCTAssertEqual(try XCTUnwrap(insights(b, t, on: date(2026, 10, 3))).spent, 30)
    }

    func testFutureDatedSpendIgnored() throws {
        let b = budget(start: date(2026, 9, 1))
        let t = [txn(80, date(2026, 10, 9))]
        XCTAssertEqual(try XCTUnwrap(insights(b, t, on: date(2026, 10, 3))).spent, 0)
    }

    func testMonthResult() throws {
        let b = budget(monthly: 3100, start: date(2026, 10, 1))
        let t = [txn(250, date(2026, 10, 1)), txn(30, date(2026, 10, 2))]
        let result = try XCTUnwrap(insights(b, t, on: date(2026, 10, 2)))
        XCTAssertEqual(result.monthResult.budgeted, 200)
        XCTAssertEqual(result.monthResult.spent, 280)
        XCTAssertEqual(result.monthResult.delta, -80)
        XCTAssertEqual(result.monthResult.endingCarry, -80)

        let reset = budget(monthly: 3100, start: date(2026, 10, 1), carries: false)
        XCTAssertEqual(try XCTUnwrap(insights(reset, t, on: date(2026, 10, 2))).monthResult.endingCarry, 0)
    }

    func testFutureStartDateYieldsNoInsights() {
        let b = budget(start: date(2026, 10, 20))
        XCTAssertNil(insights(b, [], on: date(2026, 10, 5)))
    }

    func testNoBudgetYieldsNilAndStoreOverloadToo() {
        XCTAssertNil(insights(nil, on: date(2026, 10, 5)))
        XCTAssertNil(BudgetSummaryCalculator.insights(
            budget: nil, transactions: [], isAccountBackfillComplete: true, referenceDate: date(2026, 10, 5), calendar: calendar
        ))
    }

    func testStoreOverloadReadsStores() throws {
        let b = budget(start: date(2026, 9, 1), accounts: ["a1", "a2"])
        let defaults = UserDefaults(suiteName: "BudgetSummaryCalculatorTests-\(UUID().uuidString)")!
        let accountStore = LinkedAccountStore(defaults: defaults)
        accountStore.upsert([account("a1", name: "Checking"), account("a2", name: "Card", mask: "9")])
        let result = try XCTUnwrap(BudgetSummaryCalculator.insights(
            budget: b, transactions: [], isAccountBackfillComplete: true, referenceDate: date(2026, 10, 5),
            accountStore: accountStore, itemStore: LinkedItemStore(defaults: defaults), calendar: calendar
        ))
        XCTAssertEqual(Set(try XCTUnwrap(result.breakdown).rows.map(\.title)), ["Checking ••0001", "Card ••9"])
    }

    // MARK: - Gating

    func testSyncingAndChooseAccountsGate() {
        let b = budget(start: date(2026, 9, 1))
        XCTAssertNil(insights(b, [], on: date(2026, 10, 5), backfill: false))
        let empty = budget(start: date(2026, 9, 1), accounts: [])
        XCTAssertNil(insights(empty, [], on: date(2026, 10, 5)))
    }

    // MARK: - Projection

    private func spendThrough(day: Int, daily: Decimal) -> [SpendTransaction] {
        (1...day).map { txn(daily, date(2026, 10, $0)) }
    }

    func testProjectionHiddenUntilSevenCompletedDays() throws {
        let b = budget(monthly: 3100, start: date(2026, 9, 1))
        let t = spendThrough(day: 8, daily: 100)
        for day in 1...7 {
            XCTAssertNil(try XCTUnwrap(insights(b, t, on: date(2026, 10, day))).projection, "day \(day)")
        }
        XCTAssertEqual(BudgetSummaryCalculator.projectionMinimumCompletedDays, 7)
        XCTAssertNotNil(try XCTUnwrap(insights(b, t, on: date(2026, 10, 8))).projection)
    }

    func testProjectionNumbers() throws {
        // Spent 80/day through the 7th, 500 today (day 8). rate = 7*80/7 = 80.
        // projected = (560 + 500) + 80 * 23 = 2900; budget 3100 => 200 under.
        let b = budget(monthly: 3100, start: date(2026, 9, 1))
        var t = spendThrough(day: 7, daily: 80)
        t.append(txn(500, date(2026, 10, 8)))
        let projection = try XCTUnwrap(insights(b, t, on: date(2026, 10, 8))?.projection)
        XCTAssertEqual(projection.dailyRate, 80)
        XCTAssertEqual(projection.projectedMonthTotal, 2900)
        XCTAssertEqual(projection.windowBudget, 3100)
        XCTAssertEqual(projection.projectedDelta, 200)
        XCTAssertEqual(projection.text, "At this pace you'll finish about $200 under budget.")
    }

    func testProjectionOverAndRightOn() throws {
        let b = budget(monthly: 3100, start: date(2026, 9, 1))
        let over = spendThrough(day: 8, daily: 150)
        // rate 150; projected 1200 + 150*23 = 4650; over 1550
        XCTAssertEqual(try XCTUnwrap(insights(b, over, on: date(2026, 10, 8))?.projection).text,
                       "At this pace you'll finish about $1,550 over budget.")
        let exact = spendThrough(day: 8, daily: 100)
        XCTAssertEqual(try XCTUnwrap(insights(b, exact, on: date(2026, 10, 8))?.projection).text,
                       "At this pace you'll finish right on budget.")
    }

    func testProjectionHiddenOnLastDay() throws {
        let b = budget(monthly: 3100, start: date(2026, 9, 1))
        let t = spendThrough(day: 31, daily: 100)
        XCTAssertNil(try XCTUnwrap(insights(b, t, on: date(2026, 10, 31))).projection)
        XCTAssertNotNil(try XCTUnwrap(insights(b, t, on: date(2026, 10, 30))).projection)
    }

    func testProjectionUsesWindowBudgetForMidMonthStart() throws {
        // Start Oct 10: window Oct 10..31 = 22 days = 2200 budget. Reference Oct 17 => 7 completed.
        let b = budget(monthly: 3100, start: date(2026, 10, 10))
        let t = (10...17).map { txn(100, date(2026, 10, $0)) }
        let projection = try XCTUnwrap(insights(b, t, on: date(2026, 10, 17))?.projection)
        XCTAssertEqual(projection.windowBudget, 2200)
        XCTAssertEqual(projection.dailyRate, 100)
        // spent 800 + 100 * 14 = 2200 => right on
        XCTAssertEqual(projection.projectedMonthTotal, 2200)
        XCTAssertEqual(projection.text, "At this pace you'll finish right on budget.")
        // 6 completed days => hidden
        XCTAssertNil(try XCTUnwrap(insights(b, t, on: date(2026, 10, 16))).projection)
    }

    // MARK: - Months

    func testFebruaryLeapAndNonLeap() throws {
        let b = budget(monthly: 2900, start: date(2023, 1, 1))
        XCTAssertEqual(try XCTUnwrap(insights(b, [], on: date(2024, 2, 10))).daysInMonth, 29)
        XCTAssertEqual(try XCTUnwrap(insights(b, [], on: date(2025, 2, 10))).daysInMonth, 28)
        // 2900/29 = 100 per day over 10 days
        XCTAssertEqual(try XCTUnwrap(insights(b, [], on: date(2024, 2, 10))).budgetedToDate, 1000)
        // Full-month window budget equals the monthly amount exactly on the 28th-day month.
        let t = (1...8).map { txn(100, date(2025, 2, $0)) }
        let p = try XCTUnwrap(insights(b, t, on: date(2025, 2, 8))?.projection)
        XCTAssertEqual(p.windowBudget, 2900)
    }

    func testMonthBoundaryResetsWindow() throws {
        let b = budget(start: date(2026, 9, 1))
        let t = [txn(500, date(2026, 9, 30))]
        let lastDay = try XCTUnwrap(insights(b, t, on: date(2026, 9, 30)))
        XCTAssertEqual(lastDay.spent, 500)
        let firstDay = try XCTUnwrap(insights(b, t, on: date(2026, 10, 1)))
        XCTAssertEqual(firstDay.spent, 0)
        XCTAssertEqual(firstDay.dayOfMonth, 1)
        XCTAssertNil(firstDay.trackingSince)
    }

    // MARK: - Breakdown

    func testBreakdownOrderingZeroRowsAndNames() throws {
        let b = budget(start: date(2026, 9, 1), accounts: ["a1", "a2", "a3"])
        let t = [txn(40, date(2026, 10, 2), account: "a2"), txn(90, date(2026, 10, 3), account: "a3"), txn(5, date(2026, 10, 3), account: "a2")]
        let accounts = [account("a1", name: "Checking", mask: "1111"), account("a2", name: "Visa", mask: "2222"), account("a3", name: "Savings", mask: nil)]
        let rows = try XCTUnwrap(insights(b, t, on: date(2026, 10, 4), accounts: accounts)?.breakdown).rows
        XCTAssertEqual(rows.map(\.accountID), ["a3", "a2", "a1"])
        XCTAssertEqual(rows.map(\.title), ["Savings", "Visa ••2222", "Checking ••1111"])
        XCTAssertEqual(rows.map(\.spent), [90, 45, 0])
    }

    func testBreakdownTieBreakIsStable() throws {
        let b = budget(start: date(2026, 9, 1), accounts: ["b", "a"])
        let accounts = [account("a", name: "Same", mask: nil), account("b", name: "Same", mask: nil)]
        let rows = try XCTUnwrap(insights(b, [], on: date(2026, 10, 4), accounts: accounts)?.breakdown).rows
        XCTAssertEqual(rows.map(\.accountID), ["a", "b"])
        let named = [account("a", name: "Zed", mask: nil), account("b", name: "Abe", mask: nil)]
        XCTAssertEqual(try XCTUnwrap(insights(b, [], on: date(2026, 10, 4), accounts: named)?.breakdown).rows.map(\.accountID), ["b", "a"])
    }

    func testBreakdownHiddenForSingleAccount() throws {
        let b = budget(start: date(2026, 9, 1), accounts: ["a1"])
        XCTAssertNil(try XCTUnwrap(insights(b, [], on: date(2026, 10, 4), accounts: [account("a1")])).breakdown)
    }

    func testUnknownRemovedAndNeedsRelinkRows() throws {
        let b = budget(start: date(2026, 9, 1), accounts: ["ok", "relink", "unknown", "gone"])
        let t = [
            txn(10, date(2026, 10, 2), account: "unknown", item: "item-1"),
            txn(20, date(2026, 10, 2), account: "gone", item: "removed-item"),
        ]
        let accounts = [account("ok", name: "Ok", mask: "1"), account("relink", name: "Stale", mask: "2", item: "item-2")]
        let items = [
            LinkedItem(itemID: "item-1", institutionName: "A", linkedAt: date(2026, 1, 1)),
            LinkedItem(itemID: "item-2", institutionName: "B", linkedAt: date(2026, 1, 1), needsAttention: true),
        ]
        let breakdown = try XCTUnwrap(insights(b, t, on: date(2026, 10, 4), accounts: accounts, items: items)?.breakdown)
        let byID = Dictionary(uniqueKeysWithValues: breakdown.rows.map { ($0.accountID, $0) })
        XCTAssertEqual(byID["unknown"]?.title, "Unknown account")
        XCTAssertEqual(byID["unknown"]?.isRemoved, false)
        XCTAssertEqual(byID["gone"]?.title, "Removed account")
        XCTAssertEqual(byID["gone"]?.isRemoved, true)
        XCTAssertEqual(byID["relink"]?.needsRelink, true)
        XCTAssertEqual(byID["ok"]?.needsRelink, false)
        XCTAssertEqual(breakdown.unlinkedCaption, "1 account no longer linked.")
    }

    func testUnlinkedCaptionPluralAndAbsent() throws {
        let b = budget(start: date(2026, 9, 1), accounts: ["x", "y"])
        let two = try XCTUnwrap(insights(b, [], on: date(2026, 10, 4))?.breakdown)
        XCTAssertEqual(two.unlinkedCaption, "2 accounts no longer linked.")
        let none = try XCTUnwrap(insights(b, [], on: date(2026, 10, 4), accounts: [account("x"), account("y")])?.breakdown)
        XCTAssertNil(none.unlinkedCaption)
    }

    func testInsightsRoundTripCodable() throws {
        let b = budget(start: date(2026, 9, 1), accounts: ["a1", "a2"])
        let value = try XCTUnwrap(insights(b, spendThrough(day: 8, daily: 100), on: date(2026, 10, 8), accounts: [account("a1"), account("a2")]))
        let decoded = try JSONDecoder().decode(BudgetSummaryCalculator.BudgetInsights.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(decoded, value)
    }

    func testWholeDollarFormatting() {
        XCTAssertEqual(BudgetSummaryCalculator.whole(1240), "$1,240")
        XCTAssertEqual(BudgetSummaryCalculator.whole(0.5), "$1")
        XCTAssertEqual(BudgetSummaryCalculator.whole(59.4), "$59")
    }
}
