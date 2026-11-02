import XCTest
import SwiftData
@testable import Reservoir

/// `WidgetSnapshotBuilder` maps the existing calculators into the widget's value type;
/// these tests pin the mapping (states, today vs. tomorrow, month boundary) rather than
/// re-testing the calculators' math.
final class WidgetSnapshotBuilderTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }()

    private func date(_ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    private struct EmptyAccountStore: LinkedAccountStoring {
        func loadAll() -> [LinkedAccount] { [] }
        func upsert(_ accounts: [LinkedAccount]) {}
        func removeAll(itemID: String) {}
    }

    private struct EmptyItemStore: LinkedItemStoring {
        func loadAll() -> [LinkedItem] { [] }
        func save(_ item: LinkedItem) {}
        func remove(itemID: String) {}
        func setNeedsAttention(_ needsAttention: Bool, itemID: String) {}
    }

    private func makeContext() throws -> ModelContext {
        let schema = Schema(versionedSchema: SchemaV11.self)
        let container = try ModelContainer(
            for: schema, migrationPlan: ReservoirMigrationPlan.self,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        return ModelContext(container)
    }

    private func build(
        goals: [SavingsGoal] = [], budget: Budget? = nil, transactions: [SpendTransaction] = [],
        backfillComplete: Bool = true, now: Date
    ) -> WidgetSnapshot {
        WidgetSnapshotBuilder.make(
            goals: goals, budget: budget, transactions: transactions,
            isAccountBackfillComplete: backfillComplete, now: now, calendar: calendar,
            accountStore: EmptyAccountStore(), itemStore: EmptyItemStore()
        )
    }

    private func spend(_ amount: Decimal, on when: Date, goal: SavingsGoal? = nil, account: String? = "a") -> SpendTransaction {
        SpendTransaction(
            amount: amount, date: when, merchantName: "M", type: .variable, entryMethod: .imported,
            plaidAccountID: account, savingsGoal: goal
        )
    }

    private func goal(target: Date, start: Date, base: Decimal = 10, dismissedAt: Date? = nil) -> SavingsGoal {
        SavingsGoal(
            targetAmount: 10_000, targetDate: target, startDate: start, startingBalance: 0,
            dailyBase: base, dismissedAt: dismissedAt, createdAt: start
        )
    }

    // MARK: Budget

    func testActiveBudgetFiguresAndTomorrowEstimate() throws {
        let context = try makeContext()
        let budget = Budget(monthlyAmount: 3100, startDate: date(10, 26), selectedAccountIDs: ["a"])
        context.insert(budget)
        let txs = [spend(30, on: date(10, 26, 9)), spend(40, on: date(10, 27, 9))]
        txs.forEach(context.insert)

        let snapshot = build(budget: budget, transactions: txs, now: date(10, 27))
        // Oct base 100/day. Today: carry 100-30=70, limit 170, spent 40.
        XCTAssertEqual(snapshot.today.budget, .active(remaining: 130, limit: 170, spentToday: 40))
        // Tomorrow: carry 70+100-40=130, limit 230, nothing spent yet.
        XCTAssertEqual(snapshot.tomorrow.budget, .active(remaining: 230, limit: 230, spentToday: 0))
        XCTAssertEqual(snapshot.tomorrowStart, calendar.startOfDay(for: date(10, 28)))
        XCTAssertEqual(snapshot.generatedAt, date(10, 27))
    }

    func testOverLimitProducesNegativeRemaining() throws {
        let context = try makeContext()
        let budget = Budget(monthlyAmount: 3100, startDate: date(10, 27), selectedAccountIDs: ["a"])
        context.insert(budget)
        let tx = spend(130, on: date(10, 27, 9))
        context.insert(tx)

        let snapshot = build(budget: budget, transactions: [tx], now: date(10, 27))
        XCTAssertEqual(snapshot.today.budget, .active(remaining: -30, limit: 100, spentToday: 130))
        // The debt carries into the estimate: 100 base - 30 overspend.
        XCTAssertEqual(snapshot.tomorrow.budget, .active(remaining: 70, limit: 70, spentToday: 0))
    }

    func testSyncingAndChooseAccountsHaveNoFiguresOrMonth() throws {
        let context = try makeContext()
        let selected = Budget(monthlyAmount: 3100, startDate: date(10, 1), selectedAccountIDs: ["a"])
        let empty = Budget(monthlyAmount: 3100, startDate: date(10, 1), selectedAccountIDs: [])
        context.insert(selected)
        context.insert(empty)

        let syncing = build(budget: selected, backfillComplete: false, now: date(10, 27))
        XCTAssertEqual(syncing.today.budget, .message(.syncing))
        XCTAssertEqual(syncing.tomorrow.budget, .message(.syncing))
        XCTAssertNil(syncing.today.month)

        let choose = build(budget: empty, now: date(10, 27))
        XCTAssertEqual(choose.today.budget, .message(.chooseAccounts))
        XCTAssertEqual(choose.tomorrow.budget, .message(.chooseAccounts))
        XCTAssertNil(choose.today.month)
        XCTAssertNil(choose.tomorrow.month)
    }

    func testNoBudgetAndNoGoalIsNotSetEverywhere() {
        let snapshot = build(now: date(10, 27))
        for figures in [snapshot.today, snapshot.tomorrow] {
            XCTAssertEqual(figures.budget, .notSet)
            XCTAssertEqual(figures.savings, .notSet)
            XCTAssertNil(figures.month)
        }
    }

    // MARK: Savings

    func testSavingsOnly() throws {
        let context = try makeContext()
        let g = goal(target: date(11, 30), start: date(10, 1))
        context.insert(g)
        let tx = spend(5, on: date(10, 27, 9), goal: g, account: nil)
        context.insert(tx)

        let snapshot = build(goals: [g], transactions: [tx], now: date(10, 27))
        XCTAssertEqual(snapshot.today.budget, .notSet)
        // 26 prior days x 10 = 260 carry + 10 base, 5 spent.
        XCTAssertEqual(snapshot.today.savings, .active(remaining: 265, limit: 270, spentToday: 5))
        XCTAssertEqual(snapshot.tomorrow.savings, .active(remaining: 275, limit: 275, spentToday: 0))
        XCTAssertNil(snapshot.today.month)
    }

    func testBudgetAndSavingsTogether() throws {
        let context = try makeContext()
        let budget = Budget(monthlyAmount: 3100, startDate: date(10, 27), selectedAccountIDs: ["a"])
        let g = goal(target: date(11, 30), start: date(10, 27))
        context.insert(budget)
        context.insert(g)

        let snapshot = build(goals: [g], budget: budget, now: date(10, 27))
        XCTAssertEqual(snapshot.today.budget, .active(remaining: 100, limit: 100, spentToday: 0))
        XCTAssertEqual(snapshot.today.savings, .active(remaining: 10, limit: 10, spentToday: 0))
        XCTAssertNotNil(snapshot.today.month)
    }

    func testCompletedGoalWithoutActiveGoalIsNotSet() throws {
        let context = try makeContext()
        let done = goal(target: date(10, 20), start: date(10, 1))
        context.insert(done)
        let snapshot = build(goals: [done], now: date(10, 27))
        XCTAssertEqual(snapshot.today.savings, .notSet)
        XCTAssertEqual(snapshot.tomorrow.savings, .notSet)
    }

    func testSavingsGoalEndingTodayIsNotSetTomorrow() throws {
        let context = try makeContext()
        let g = goal(target: date(10, 27), start: date(10, 1))
        context.insert(g)
        let snapshot = build(goals: [g], now: date(10, 27))
        XCTAssertEqual(snapshot.today.savings.state, .active)
        XCTAssertEqual(snapshot.tomorrow.savings, .notSet)
    }

    // MARK: Month boundary

    func testTomorrowEstimateCrossingFirstCarriesOverInCarryMode() throws {
        let context = try makeContext()
        // 930/month: Oct 31 days -> 30/day, Nov 30 days -> 31/day.
        let budget = Budget(
            monthlyAmount: 930, startDate: date(10, 30), carriesAcrossMonths: true, selectedAccountIDs: ["a"]
        )
        context.insert(budget)
        let txs = [spend(10, on: date(10, 30, 9)), spend(5, on: date(10, 31, 9))]
        txs.forEach(context.insert)

        let snapshot = build(budget: budget, transactions: txs, now: date(10, 31))
        XCTAssertEqual(snapshot.today.budget, .active(remaining: 45, limit: 50, spentToday: 5))
        // Carry 20 + 30 - 5 = 45, plus November's 31 base.
        XCTAssertEqual(snapshot.tomorrow.budget, .active(remaining: 76, limit: 76, spentToday: 0))
        XCTAssertEqual(snapshot.tomorrowStart, calendar.startOfDay(for: date(11, 1)))
        XCTAssertEqual(snapshot.today.month?.monthName, "October")
        XCTAssertEqual(snapshot.tomorrow.month?.monthName, "November")
        XCTAssertEqual(snapshot.tomorrow.month?.spent, 0)
    }

    func testTomorrowEstimateCrossingFirstResetsInResetMode() throws {
        let context = try makeContext()
        let budget = Budget(
            monthlyAmount: 930, startDate: date(10, 30), carriesAcrossMonths: false, selectedAccountIDs: ["a"]
        )
        context.insert(budget)
        let txs = [spend(10, on: date(10, 30, 9)), spend(5, on: date(10, 31, 9))]
        txs.forEach(context.insert)

        let snapshot = build(budget: budget, transactions: txs, now: date(10, 31))
        // Today is unaffected by the reset (no 1st crossed yet).
        XCTAssertEqual(snapshot.today.budget, .active(remaining: 45, limit: 50, spentToday: 5))
        // Tomorrow is the 1st: carry zeroed, just November's base.
        XCTAssertEqual(snapshot.tomorrow.budget, .active(remaining: 31, limit: 31, spentToday: 0))
    }

    // MARK: Medium month panel

    func testMonthProgressDataForBudgetOnly() throws {
        let context = try makeContext()
        let budget = Budget(monthlyAmount: 3100, startDate: date(10, 1), selectedAccountIDs: ["a"])
        context.insert(budget)
        let txs = [spend(200, on: date(10, 3, 9)), spend(50, on: date(10, 27, 9))]
        txs.forEach(context.insert)

        let snapshot = build(budget: budget, transactions: txs, now: date(10, 27))
        let month = try XCTUnwrap(snapshot.today.month)
        XCTAssertEqual(month.monthName, "October")
        XCTAssertEqual(month.spent, 250)
        XCTAssertEqual(month.monthlyAmount, 3100)
        XCTAssertFalse(month.sentence.isEmpty)
        XCTAssertEqual(snapshot.today.savings, .notSet)
    }

    func testMonthNameUsesCalendarLocale() {
        XCTAssertEqual(WidgetSnapshotBuilder.monthName(for: date(2, 10), calendar: calendar), "February")
    }

    func testSnapshotContainsNoMerchantOrAccountStrings() throws {
        let context = try makeContext()
        let budget = Budget(monthlyAmount: 3100, startDate: date(10, 27), selectedAccountIDs: ["secret-acct"])
        context.insert(budget)
        let tx = SpendTransaction(
            amount: 10, date: date(10, 27, 9), merchantName: "Secret Merchant", type: .variable,
            entryMethod: .imported, plaidAccountID: "secret-acct", savingsGoal: nil
        )
        context.insert(tx)
        let data = try JSONEncoder().encode(build(budget: budget, transactions: [tx], now: date(10, 27)))
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("Secret Merchant"))
        XCTAssertFalse(json.contains("secret-acct"))
    }
}
