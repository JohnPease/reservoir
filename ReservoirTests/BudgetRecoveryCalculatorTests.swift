import XCTest
import SwiftData
@testable import Reservoir

/// reservoir-nka.1: recovery at the usual pace, the target line, month warnings and the Today
/// banner. Most cases drive the pure `BudgetRecoveryCalculator.result` with hand-built inputs; a
/// few go through `BudgetSummaryCalculator.insights` with an in-memory container so the carry-in
/// identity and the lookback wiring are checked against the real carry walk.
final class BudgetRecoveryCalculatorTests: XCTestCase {

    private typealias Calc = BudgetRecoveryCalculator

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        let schema = Schema(versionedSchema: SchemaV12.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, migrationPlan: ReservoirMigrationPlan.self, configurations: [configuration])
        context = ModelContext(container)
    }

    override func tearDownWithError() throws {
        context = nil
        container = nil
    }

    // MARK: - Helpers

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0, in cal: Calendar? = nil) -> Date {
        (cal ?? calendar).date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    /// `value` on each of the `days` completed days before `today` (keys built independently of
    /// the calculator: noon minus n days, then `startOfDay`).
    private func history(_ value: Decimal, days: Int, before today: Date, cal: Calendar? = nil) -> [Date: Decimal] {
        let cal = cal ?? calendar
        let noon = cal.date(byAdding: .hour, value: 12, to: today)!
        var result: [Date: Decimal] = [:]
        for back in 1...days {
            result[cal.startOfDay(for: cal.date(byAdding: .day, value: -back, to: noon)!)] = value
        }
        return result
    }

    /// A consistent input for `today`: `budgetedToDate` is the month's bases through today and
    /// `paceDelta = budgetedToDate - spent`. `remaining` is `-debt` when `debt` is given, else
    /// `carryIn + paceDelta` (carry) / `paceDelta` (reset). `usual` seeds 14 history days.
    private func input(
        today: Date,
        monthly: Decimal = 3000,
        boundary: MonthBoundary = .carry,
        carryIn: Decimal = 0,
        spent: Decimal = 0,
        windowBudget: Decimal? = nil,
        projectedDelta: Decimal? = nil,
        debt: Decimal? = nil,
        usual: Decimal? = nil,
        spentByDay: [Date: Decimal]? = nil,
        start: Date? = nil,
        cal: Calendar? = nil
    ) -> Calc.Input {
        let cal = cal ?? calendar
        let dayOfMonth = cal.component(.day, from: today)
        let daysInMonth = cal.range(of: .day, in: .month, for: today)!.count
        let monthStart = cal.dateInterval(of: .month, for: today)!.start
        let schedule = BaseSchedule.monthly(monthly)
        let budgeted = BudgetSummaryCalculator.baseSum(schedule, from: monthStart, days: dayOfMonth, calendar: cal)
        let paceDelta = budgeted - spent
        let remaining = debt.map { -$0 } ?? ((boundary == .carry ? carryIn : 0) + paceDelta)
        return Calc.Input(
            monthlyAmount: monthly,
            monthBoundary: boundary,
            today: cal.startOfDay(for: today),
            remaining: remaining,
            spent: spent,
            windowBudget: windowBudget ?? monthly,
            budgetedToDate: budgeted,
            paceDelta: paceDelta,
            projectedDelta: projectedDelta,
            dayOfMonth: dayOfMonth,
            daysInMonth: daysInMonth,
            spentByDay: spentByDay ?? usual.map { history($0, days: 14, before: today, cal: cal) } ?? [:],
            budgetStartDay: start ?? date(2025, 1, 1, in: cal)
        )
    }

    private func result(_ input: Calc.Input, cal: Calendar? = nil) -> Calc.Result {
        Calc.result(input, calendar: cal ?? calendar)
    }

    private func txn(_ amount: Decimal, _ day: Date, account: String? = "a1", type: TransactionType = .variable) -> SpendTransaction {
        let transaction = SpendTransaction(
            amount: amount, date: day, merchantName: "M", type: type, entryMethod: .imported,
            plaidItemID: "item-1", plaidAccountID: account
        )
        context.insert(transaction)
        return transaction
    }

    private func budget(monthly: Decimal = 3000, start: Date, carries: Bool = true) -> Budget {
        let budget = Budget(monthlyAmount: monthly, startDate: start, carriesAcrossMonths: carries, selectedAccountIDs: ["a1"])
        context.insert(budget)
        return budget
    }

    private func insights(_ budget: Budget, _ transactions: [SpendTransaction], on day: Date) throws -> BudgetSummaryCalculator.BudgetInsights {
        try XCTUnwrap(BudgetSummaryCalculator.insights(
            budget: budget, transactions: transactions, isAccountBackfillComplete: true,
            referenceDate: day, linkedAccounts: [], linkedItems: [], calendar: calendar
        ))
    }

    /// Independent carry into `month`: walk every day from the budget start to the 1st.
    private func walkedCarry(_ budget: Budget, _ transactions: [SpendTransaction], into month: Date) -> Decimal {
        let spentByDay = BudgetCalculator.countedSpendByDay(transactions, for: budget, calendar: calendar)
        var carry: Decimal = 0
        var day = calendar.startOfDay(for: budget.startDate)
        while day < month {
            carry += BaseSchedule.monthly(budget.monthlyAmount).base(on: day, calendar: calendar) - (spentByDay[day] ?? 0)
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        return carry
    }

    // MARK: - Carry-in identity

    func testCarryInMatchesAnIndependentCarryWalk() throws {
        // Sep 2026 at 3100/month; the October carry-in is checked against a fresh day walk.
        let start = date(2026, 9, 1)
        let cases: [(String, [SpendTransaction])] = [
            ("positive", [txn(1000, date(2026, 9, 10))]),
            ("negative", [txn(3600, date(2026, 9, 10))]),
            ("zero", [txn(3100, date(2026, 9, 10))]),
        ]
        for (name, transactions) in cases {
            let b = budget(monthly: 3100, start: start)
            let all = transactions + [txn(250, date(2026, 10, 3)), txn(40, date(2026, 10, 9))]
            let value = try insights(b, all, on: date(2026, 10, 9))
            XCTAssertEqual(value.recovery.carryIn, walkedCarry(b, all, into: date(2026, 10, 1)), name)
        }
    }

    func testCarryInSigns() throws {
        let b = budget(monthly: 3100, start: date(2026, 9, 1))
        XCTAssertEqual(try insights(b, [txn(1000, date(2026, 9, 10))], on: date(2026, 10, 9)).recovery.carryIn, 2100)
        let over = budget(monthly: 3100, start: date(2026, 9, 1))
        XCTAssertEqual(try insights(over, [txn(3600, date(2026, 9, 10))], on: date(2026, 10, 9)).recovery.carryIn, -500)
    }

    func testCarryInIsZeroWhenTheBudgetStartedThisMonthOrResets() throws {
        let fresh = budget(start: date(2026, 11, 5))
        let t = [txn(900, date(2026, 11, 6))]
        XCTAssertEqual(try insights(fresh, t, on: date(2026, 11, 10)).recovery.carryIn, 0)

        let reset = budget(start: date(2026, 9, 1), carries: false)
        XCTAssertEqual(try insights(reset, [txn(9000, date(2026, 10, 10))], on: date(2026, 11, 10)).recovery.carryIn, 0)
        XCTAssertEqual(Calc.carryIn(remaining: -50, paceDelta: 20, boundary: .reset), 0)
        XCTAssertEqual(Calc.carryIn(remaining: -50, paceDelta: 20, boundary: .carry), -70)
    }

    // MARK: - Debt

    func testDebtThresholdIsOneDollar() {
        XCTAssertNil(result(input(today: date(2026, 11, 10), debt: Decimal(string: "0.99")!, usual: 40)).recovery)
        let owed = result(input(today: date(2026, 11, 10), debt: 1, usual: 40)).recovery
        XCTAssertEqual(owed?.debt, 1)
    }

    func testTodaysSpendCreatesDebtWhileCarryIsPositive() throws {
        // Nov base 100; $90 a day banks +$90 by the 10th, then $300 today: remaining = 190 - 300.
        let b = budget(start: date(2026, 11, 1))
        let t = (1...9).map { txn(90, date(2026, 11, $0)) } + [txn(300, date(2026, 11, 10))]
        let summary = try XCTUnwrap(BudgetCalculator.summary(budget: b, allTransactions: t, referenceDate: date(2026, 11, 10), calendar: calendar))
        XCTAssertEqual(summary.carriedForward, 90)
        let recovery = try XCTUnwrap(try insights(b, t, on: date(2026, 11, 10)).recovery.recovery)
        XCTAssertEqual(recovery.debt, -summary.remaining)
        XCTAssertEqual(recovery.debt, 110)
    }

    // MARK: - Usual pace

    private func usual(_ spentByDay: [Date: Decimal], today: Date, start: Date? = nil, monthly: Decimal = 3000) -> Decimal? {
        Calc.usualDailySpend(
            spentByDay: spentByDay, today: today, budgetStartDay: start ?? date(2025, 1, 1),
            schedule: .monthly(monthly), calendar: calendar
        )
    }

    func testUsualPaceCountsZeroDaysAndExcludesToday() {
        let today = date(2026, 11, 20)
        var days: [Date: Decimal] = [date(2026, 11, 12): 140]
        days[today] = 1000
        XCTAssertEqual(usual(days, today: today), 10)
    }

    func testUsualPaceIsFlooredAtTheBudgetStart() {
        let today = date(2026, 11, 20)
        XCTAssertEqual(usual(history(70, days: 14, before: today), today: today, start: date(2026, 11, 13)), 70)
    }

    func testUsualPaceNeedsSevenCompletedDays() {
        let today = date(2026, 11, 20)
        XCTAssertNil(usual(history(70, days: 14, before: today), today: today, start: date(2026, 11, 14)))
        XCTAssertEqual(usual(history(70, days: 14, before: today), today: today, start: date(2026, 11, 13)), 70)
    }

    func testUsualPaceIgnoresFutureDatedSpendAndOlderDays() {
        let today = date(2026, 11, 20)
        var days = history(28, days: 14, before: today)
        days[date(2026, 11, 22)] = 5000
        days[date(2026, 11, 5)] = 5000 // 15 days back: outside the window
        XCTAssertEqual(usual(days, today: today), 28)
    }

    func testUsualPaceCapsEachDayAtTwiceItsBase() {
        let today = date(2026, 11, 20)
        XCTAssertEqual(usual([date(2026, 11, 15): 1000], today: today), Decimal(200) / 14)
    }

    func testCountedSpendByDayIgnoresFixedAndUnselectedAccounts() {
        let b = budget(start: date(2026, 11, 1))
        let t = [
            txn(30, date(2026, 11, 2, hour: 9)), txn(20, date(2026, 11, 2, hour: 18)),
            txn(50, date(2026, 11, 2), type: .fixed), txn(70, date(2026, 11, 2), account: "other"),
            txn(90, date(2026, 10, 30)),
        ]
        XCTAssertEqual(BudgetCalculator.countedSpendByDay(t, for: b, calendar: calendar), [date(2026, 11, 2): 50])
    }

    func testUsualPaceThroughInsightsIgnoresFixedUnselectedAndToday() throws {
        let b = budget(start: date(2026, 11, 1))
        var t = (6...19).map { txn(150, date(2026, 11, $0)) }
        t += [txn(900, date(2026, 11, 12), type: .fixed), txn(900, date(2026, 11, 12), account: "other"), txn(400, date(2026, 11, 20))]
        let recovery = try XCTUnwrap(try insights(b, t, on: date(2026, 11, 20)).recovery.recovery)
        XCTAssertEqual(recovery.usualDaily, 150)
    }

    // MARK: - Recovery

    private func outcome(_ input: Calc.Input, cal: Calendar? = nil) -> Calc.Outcome? {
        result(input, cal: cal).recovery?.outcome
    }

    func testRecoveryWithinTheMonthIsTheCeilingOfDebtOverDailyGain() {
        // Nov: base 100, usual 40 => +60/day.
        XCTAssertEqual(outcome(input(today: date(2026, 11, 10), debt: 300, usual: 40)), .days(5, on: date(2026, 11, 15)))
        XCTAssertEqual(outcome(input(today: date(2026, 11, 10), debt: 310, usual: 40)), .days(6, on: date(2026, 11, 16)))
    }

    func testRecoveryNeverWhenUsualPaceMatchesOrExceedsTheBase() {
        // Feb 2027 at 2800/month: base 100 = amount / 28, the largest any day gets.
        XCTAssertEqual(outcome(input(today: date(2027, 2, 10), monthly: 2800, debt: 50, usual: 100)), .never)
        XCTAssertEqual(outcome(input(today: date(2026, 11, 10), debt: 50, usual: 110)), .never)
        // U == Nov's base: later months net to zero at best, so never.
        XCTAssertEqual(outcome(input(today: date(2026, 11, 24), debt: 50, usual: 100)), .never)
        // Reset mode: the same pace resets on the 1st.
        XCTAssertEqual(outcome(input(today: date(2026, 11, 24), boundary: .reset, debt: 50, usual: 100)), .resetsOnFirst(date(2026, 12, 1)))
    }

    func testUsualPaceBetweenThirtyFirstAndTwentyEighthCatchesUpInFebruary() {
        // Jan 2027 base 96.77 < U 100 < Feb base 107.14: Jan 16-31 lose 51.61, Feb gains 7.14/day.
        let from = input(today: date(2027, 1, 15), debt: 50, usual: 100)
        let recovery = result(from).recovery
        XCTAssertEqual(recovery?.outcome, .days(31, on: date(2027, 2, 15)))
        XCTAssertEqual(recovery?.crossesMonth, true)
        XCTAssertEqual(outcome(input(today: date(2027, 1, 15), debt: 1000, usual: 100)), .never)
    }

    func testRecoveryCarriesAcrossA31To30DayMonth() {
        // Oct 29-31 +46.77 each, then Nov +50/day: 140.32 + 4 * 50 >= 300 on Nov 4.
        let value = result(input(today: date(2026, 10, 28), debt: 300, usual: 50))
        XCTAssertEqual(value.recovery?.outcome, .days(7, on: date(2026, 11, 4)))
        XCTAssertEqual(value.recovery?.crossesMonth, true)
        XCTAssertEqual(value.banner?.lines.first?.text, "At your usual $50 a day, your full $100 limit is back in 7 days (Wed, Nov 4), carrying into November.")
    }

    func testRecoveryCarriesFromDecemberIntoJanuary() {
        let value = result(input(today: date(2026, 12, 30), debt: 200, usual: 50))
        XCTAssertEqual(value.recovery?.outcome, .days(5, on: date(2027, 1, 4)))
        XCTAssertEqual(value.banner?.lines.first?.text, "At your usual $50 a day, your full $97 limit is back in 5 days (Mon, Jan 4), carrying into January.")
    }

    func testSpecExampleCrossingIntoDecember() {
        // 2500/month: Nov base 83.33, Dec 80.65; usual 61.
        let value = result(input(today: date(2026, 11, 24), monthly: 2500, debt: 150, usual: 61))
        XCTAssertEqual(value.recovery?.outcome, .days(7, on: date(2026, 12, 1)))
        XCTAssertEqual(value.banner?.lines.first?.text, "At your usual $61 a day, your full $81 limit is back in 7 days (Tue, Dec 1), carrying into December.")
    }

    func testDebtCarriedIntoTheFirstShowsRecoveryWithUsualPaceFromLastMonth() throws {
        // Nov: base 100, spent 150 every day => C into Dec = -1500. Dec 1, nothing spent yet.
        let b = budget(start: date(2026, 11, 1))
        let t = (1...30).map { txn(150, date(2026, 11, $0)) }
        let value = try insights(b, t, on: date(2026, 12, 1))
        XCTAssertEqual(value.recovery.carryIn, -1500)
        let recovery = try XCTUnwrap(value.recovery.recovery)
        XCTAssertEqual(recovery.usualDaily, 150)
        XCTAssertEqual(recovery.outcome, .never)
        XCTAssertNil(recovery.target)
        XCTAssertEqual(value.recovery.warning.level, .none)
        XCTAssertEqual(value.recovery.banner?.text, "At your usual $150 a day, you won't catch up. Your limit stays below $97 until you spend less.")
    }

    func testResetModeStillBehindAtMonthEnd() {
        let value = result(input(today: date(2026, 11, 24), boundary: .reset, debt: 300, usual: 90))
        XCTAssertEqual(value.recovery?.outcome, .resetsOnFirst(date(2026, 12, 1)))
        XCTAssertEqual(value.banner?.lines.map(\.text), [
            "At your usual $90 a day, you'll still be behind when your limit resets on the 1st.",
            "Keep to $50 a day to be back by Mon, Nov 30.",
        ])
    }

    func testResetModeRecoveringExactlyOnTheLastDay() {
        let value = result(input(today: date(2026, 11, 24), boundary: .reset, debt: 300, usual: 50))
        XCTAssertEqual(value.recovery?.outcome, .days(6, on: date(2026, 11, 30)))
        XCTAssertEqual(value.recovery?.crossesMonth, false)
        XCTAssertEqual(value.banner?.text, "At your usual $50 a day, your full $100 limit is back in 6 days (Mon, Nov 30).")
    }

    func testResetModeDebtOnTheLastDayResetsTomorrow() {
        let value = result(input(today: date(2026, 11, 30), boundary: .reset, debt: 50, usual: 50))
        XCTAssertEqual(value.recovery?.outcome, .resetsOnFirst(date(2026, 12, 1)))
        XCTAssertNil(value.recovery?.target)
        XCTAssertEqual(value.banner?.text, "At your usual $50 a day, you'll still be behind when your limit resets tomorrow.")
    }

    func testOneDayRecoveryReadsTomorrow() {
        XCTAssertEqual(result(input(today: date(2026, 11, 10), debt: 50, usual: 40)).banner?.text,
                       "At your usual $40 a day, your full $100 limit is back tomorrow.")
        let crossing = result(input(today: date(2026, 11, 30), debt: 50, usual: 40))
        XCTAssertEqual(crossing.recovery?.outcome, .days(1, on: date(2026, 12, 1)))
        XCTAssertEqual(crossing.banner?.lines.first?.text, "At your usual $40 a day, your full $97 limit is back tomorrow, carrying into December.")
        // Debt on the last day of a carry month is always past the month's budget too.
        XCTAssertEqual(crossing.warning.level, .pointOfNoReturn)
    }

    func testRecoveryAtDaysLeftAndOneMore() {
        let today = date(2026, 11, 24) // 6 days left
        XCTAssertEqual(outcome(input(today: today, boundary: .reset, debt: 300, usual: 50)), .days(6, on: date(2026, 11, 30)))
        XCTAssertEqual(outcome(input(today: today, boundary: .reset, debt: Decimal(string: "300.01")!, usual: 50)), .resetsOnFirst(date(2026, 12, 1)))
        XCTAssertEqual(outcome(input(today: today, debt: Decimal(string: "300.01")!, usual: 50)), .days(7, on: date(2026, 12, 1)))
    }

    func testRecoveryUnavailableWithoutUsualPace() {
        let value = result(input(today: date(2026, 11, 10), debt: 100, usual: 40, start: date(2026, 11, 5)))
        XCTAssertEqual(value.recovery?.outcome, .unavailable)
        XCTAssertNil(value.recovery?.usualDaily)
    }

    // MARK: - Target

    private func target(_ input: Calc.Input) -> Calc.Target? {
        result(input).recovery?.target
    }

    func testTargetWithinTheMonth() {
        // U 60 against base 100 => +40/day, n = 10 => N = 5, T = (500 - 400) / 5.
        let value = result(input(today: date(2026, 11, 10), debt: 400, usual: 60))
        XCTAssertEqual(value.recovery?.outcome, .days(10, on: date(2026, 11, 20)))
        XCTAssertEqual(value.recovery?.target, Calc.Target(daily: 20, days: 5, by: date(2026, 11, 15)))
        XCTAssertEqual(value.banner?.lines.last?.text, "Keep to $20 a day to be back by Sun, Nov 15.")
    }

    func testTargetCrossingTheFirstUsesEachMonthsBase() {
        // n = 11 (Nov 28-30 +40, Dec +36.77) => N = 6, horizon Nov 28 - Dec 3.
        let value = result(input(today: date(2026, 11, 27), debt: 400, usual: 60))
        XCTAssertEqual(value.recovery?.outcome, .days(11, on: date(2026, 12, 8)))
        let expected = BudgetSummaryCalculator.wholeDollarsDown(
            (BudgetSummaryCalculator.baseSum(.monthly(3000), from: date(2026, 11, 28), days: 6, calendar: calendar) - 400) / 6
        )
        XCTAssertEqual(expected, 31)
        XCTAssertEqual(value.recovery?.target, Calc.Target(daily: 31, days: 6, by: date(2026, 12, 3)))
    }

    func testTargetHiddenUnderOneDollar() {
        // U 99 never pays down 695 => N = 7, T = (700 - 695) / 7 < 1.
        let hidden = result(input(today: date(2026, 11, 10), debt: 695, usual: 99))
        XCTAssertEqual(hidden.recovery?.outcome, .never)
        XCTAssertNil(hidden.recovery?.target)
        XCTAssertEqual(result(input(today: date(2026, 11, 10), debt: 693, usual: 99)).recovery?.target?.daily, 1)
    }

    func testTargetHiddenWhenNotNearerThanUsualPace() {
        XCTAssertEqual(result(input(today: date(2026, 11, 10), debt: 150, usual: 50)).recovery?.outcome, .days(3, on: date(2026, 11, 13)))
        XCTAssertNil(target(input(today: date(2026, 11, 10), debt: 150, usual: 50)))
        // n = 4 => N = max(2, 3) = 3 < 4: shown.
        XCTAssertEqual(target(input(today: date(2026, 11, 10), debt: 200, usual: 50)), Calc.Target(daily: 33, days: 3, by: date(2026, 11, 13)))
    }

    func testTargetClampsToSevenDays() {
        // n = 20 => ceil(20/2) = 10 => 7.
        XCTAssertEqual(target(input(today: date(2026, 11, 10), debt: 200, usual: 90)), Calc.Target(daily: 71, days: 7, by: date(2026, 11, 17)))
    }

    func testTargetUsesSevenDaysWhenNeverAndRoundsDown() {
        let value = result(input(today: date(2026, 11, 10), debt: 100, usual: 150))
        XCTAssertEqual(value.recovery?.target, Calc.Target(daily: 85, days: 7, by: date(2026, 11, 17)))
        XCTAssertEqual(value.banner?.lines.map(\.text), [
            "At your usual $150 a day, you won't catch up. Your limit stays below $100 until you spend less.",
            "Keep to $85 a day to be back by Tue, Nov 17.",
        ])
    }

    func testUsualPaceUnavailableShowsTargetOnly() {
        let value = result(input(today: date(2026, 11, 10), debt: 100, start: date(2026, 11, 5)))
        XCTAssertEqual(value.recovery?.target, Calc.Target(daily: 85, days: 7, by: date(2026, 11, 17)))
        XCTAssertEqual(value.banner?.lines.map(\.text), ["Keep to $85 a day to be back by Tue, Nov 17."])
    }

    func testResetModeCapsTheTargetAtDaysLeft() {
        let value = result(input(today: date(2026, 11, 27), boundary: .reset, debt: 200, usual: 50))
        XCTAssertEqual(value.recovery?.outcome, .resetsOnFirst(date(2026, 12, 1)))
        XCTAssertEqual(value.recovery?.target, Calc.Target(daily: 33, days: 3, by: date(2026, 11, 30)))
    }

    // MARK: - Level 1: tracking over

    func testTrackingOverThresholdCountsTheCarry() {
        let today = date(2026, 11, 10)
        XCTAssertEqual(result(input(today: today, projectedDelta: Decimal(string: "-0.99")!)).warning.level, .none)
        XCTAssertEqual(result(input(today: today, projectedDelta: -1)).warning.level, .trackingOver)
        XCTAssertEqual(result(input(today: today, carryIn: 150, projectedDelta: -100)).warning.level, .none)
        let behind = result(input(today: today, carryIn: -100, projectedDelta: 50)).warning
        XCTAssertEqual(behind.level, .trackingOver)
        XCTAssertEqual(behind.headingOver, 50)
        XCTAssertEqual(result(input(today: today, projectedDelta: nil)).warning.level, .none)
    }

    func testNeededIsFromTomorrowAndRoundedDown() {
        // available 3000 - 300 = 2700; (2700 - 1505) / 20 days left = 59.75.
        let warning = result(input(today: date(2026, 11, 10), carryIn: -300, spent: 1505, projectedDelta: 120)).warning
        XCTAssertEqual(warning.level, .trackingOver)
        XCTAssertEqual(warning.headingOver, 180)
        XCTAssertEqual(warning.neededDaily, 59)
    }

    func testTrackingOverNeedsSevenCompletedDaysThroughInsights() throws {
        let b = budget(monthly: 3100, start: date(2026, 10, 1))
        let t = (1...8).map { txn(150, date(2026, 10, $0)) }
        XCTAssertEqual(try insights(b, t, on: date(2026, 10, 7)).recovery.warning.level, .none)
        let eighth = try insights(b, t, on: date(2026, 10, 8))
        XCTAssertEqual(eighth.recovery.warning.level, .trackingOver)
        // Projected 4650 against 3100: $1,550 over; (3100 - 1200) / 23 = 82.6 => $82.
        XCTAssertEqual(eighth.recovery.banner?.lines.last?.text,
                       "Heading about $1,550 over for October. Keep to $82 a day from tomorrow to finish even.")
    }

    func testTrackingOverForAMidMonthStart() throws {
        let b = budget(monthly: 3100, start: date(2026, 10, 10))
        let t = (10...17).map { txn(150, date(2026, 10, $0)) }
        XCTAssertEqual(try insights(b, t, on: date(2026, 10, 16)).recovery.warning.level, .none)
        let warning = try insights(b, t, on: date(2026, 10, 17)).recovery.warning
        XCTAssertEqual(warning.level, .trackingOver)
        // Window 2200; projected 1200 + 150 * 14 = 3300 => 1100 over.
        XCTAssertEqual(warning.headingOver, 1100)
    }

    func testTrackingOverHiddenOnTheLastDay() throws {
        let b = budget(monthly: 3100, start: date(2026, 10, 1))
        let t = (1...30).map { txn(101, date(2026, 10, $0)) }
        XCTAssertNotEqual(try insights(b, t, on: date(2026, 10, 30)).recovery.warning.level, .none)
        let last = try insights(b, t, on: date(2026, 10, 31)).recovery.warning
        XCTAssertEqual(last.level, .none)
        XCTAssertNil(last.neededDaily)
    }

    // MARK: - Level 2: hard to recover

    func testHardToRecoverJustBelowAndAtTheLowTypicalWeek() {
        let today = date(2026, 11, 10)
        let flat = history(50, days: 90, before: today)
        // 20 days left: needed = (3000 - spent) / 20.
        let below = result(input(today: today, spent: Decimal(string: "2000.2")!, projectedDelta: -100, spentByDay: flat)).warning
        XCTAssertEqual(below.lowTypicalDaily, 50)
        XCTAssertEqual(below.level, .hardToRecover)
        XCTAssertEqual(result(input(today: today, spent: 2000, projectedDelta: -100, spentByDay: flat)).warning.level, .trackingOver)
    }

    func testZeroHeavyHistoryStillHasARollingWeeklyAverage() {
        let today = date(2026, 11, 10)
        let noon = calendar.date(byAdding: .hour, value: 12, to: today)!
        var days: [Date: Decimal] = [:]
        for back in stride(from: 7, through: 90, by: 7) {
            days[calendar.startOfDay(for: calendar.date(byAdding: .day, value: -back, to: noon)!)] = 350
        }
        let warning = result(input(today: today, spent: 2200, projectedDelta: -100, spentByDay: days)).warning
        XCTAssertEqual(warning.lowTypicalDaily, 50)
        XCTAssertEqual(warning.level, .hardToRecover)
    }

    func testHardToRecoverNeedsTwentyEightDaysOfHistory() {
        let today = date(2026, 11, 10)
        let flat = history(50, days: 90, before: today)
        let short = result(input(today: today, spent: 2900, projectedDelta: -100, spentByDay: flat, start: date(2026, 10, 14))).warning
        XCTAssertNil(short.lowTypicalDaily)
        XCTAssertEqual(short.level, .trackingOver)
        let enough = result(input(today: today, spent: 2900, projectedDelta: -100, spentByDay: flat, start: date(2026, 10, 13))).warning
        XCTAssertEqual(enough.lowTypicalDaily, 50)
        XCTAssertEqual(enough.level, .hardToRecover)
    }

    func testHardToRecoverNeverWithoutTrackingOver() {
        let today = date(2026, 11, 10)
        let flat = history(50, days: 90, before: today)
        XCTAssertEqual(result(input(today: today, spent: 2900, projectedDelta: 10, spentByDay: flat)).warning.level, .none)
        XCTAssertEqual(result(input(today: today, spent: 2900, projectedDelta: nil, spentByDay: flat)).warning.level, .none)
    }

    func testNearestRankPercentileIsPinned() {
        XCTAssertEqual(Calc.nearestRank(percentile: 10, of: (1...20).map { Decimal($0) }), 2)
        XCTAssertEqual(Calc.nearestRank(percentile: 10, of: (1...21).map { Decimal($0) }.reversed()), 3)
        XCTAssertEqual(Calc.nearestRank(percentile: 10, of: (1...10).map { Decimal($0) }), 1)
        XCTAssertEqual(Calc.nearestRank(percentile: 10, of: [5]), 5)
        XCTAssertNil(Calc.nearestRank(percentile: 10, of: []))
    }

    func testLowTypicalIsTheTenthPercentileOfRollingWeeks() {
        // 28 days: two quiet weeks (10/day) then two busy weeks (100/day) => 22 windows,
        // rank ceil(2.2) = 3 => the 3rd smallest weekly average.
        let today = date(2026, 11, 29)
        var days: [Date: Decimal] = [:]
        for offset in 0..<28 {
            days[date(2026, 11, 1) + TimeInterval(offset * 86_400)] = offset < 14 ? 10 : 100
        }
        let low = Calc.lowTypicalDailySpend(spentByDay: days, today: today, budgetStartDay: date(2026, 11, 1), calendar: calendar)
        XCTAssertEqual(low, 10)
        XCTAssertEqual(Calc.lowTypicalPercentile, 10)
    }

    // MARK: - Level 3: point of no return

    func testPointOfNoReturnThresholdIsOneDollar() {
        let today = date(2026, 11, 10)
        XCTAssertEqual(result(input(today: today, spent: Decimal(string: "3000.99")!)).warning.level, .none)
        let over = result(input(today: today, spent: 3001)).warning
        XCTAssertEqual(over.level, .pointOfNoReturn)
        XCTAssertEqual(over.overBy, 1)
    }

    func testPointOfNoReturnCountsTheCarry() {
        let today = date(2026, 11, 10)
        XCTAssertEqual(result(input(today: today, carryIn: 500, spent: 3050)).warning.level, .none)
        let behind = result(input(today: today, carryIn: -300, spent: 2750)).warning
        XCTAssertEqual(behind.level, .pointOfNoReturn)
        XCTAssertEqual(behind.overBy, 50)
        // Reset mode ignores any carry.
        XCTAssertEqual(result(input(today: today, boundary: .reset, carryIn: -300, spent: 2750)).warning.level, .none)
    }

    func testPointOfNoReturnFiresOnDayTwoAndTheLastDay() throws {
        let b = budget(monthly: 3100, start: date(2026, 10, 1))
        let t = [txn(3200, date(2026, 10, 2))]
        XCTAssertEqual(try insights(b, t, on: date(2026, 10, 2)).recovery.warning.level, .pointOfNoReturn)
        let last = try insights(b, t, on: date(2026, 10, 31)).recovery.warning
        XCTAssertEqual(last.level, .pointOfNoReturn)
        XCTAssertEqual(last.overBy, 100)
    }

    func testPointOfNoReturnForAProratedMidMonthStart() throws {
        let b = budget(monthly: 3100, start: date(2026, 10, 12))
        let warning = try insights(b, [txn(2100, date(2026, 10, 13))], on: date(2026, 10, 14)).recovery.warning
        XCTAssertEqual(warning.level, .pointOfNoReturn)
        XCTAssertEqual(warning.overBy, 100)
    }

    func testPointOfNoReturnOnTheFirstWithHugeCarriedInDebt() throws {
        let b = budget(start: date(2026, 11, 1))
        let value = try insights(b, [txn(6100, date(2026, 11, 20))], on: date(2026, 12, 1))
        XCTAssertEqual(value.recovery.carryIn, -3100)
        XCTAssertEqual(value.recovery.warning.level, .pointOfNoReturn)
        XCTAssertEqual(value.recovery.warning.overBy, 100)
        XCTAssertEqual(value.recovery.banner?.lines.map(\.text), [
            "At your usual $14 a day, your full $97 limit is back in 37 days (Thu, Jan 7), carrying into January.",
            "December's budget is spent, $100 over counting the $3,100 you started behind. More spending this month carries into January.",
        ])
        XCTAssertEqual(value.recovery.banner?.lines.last?.deficitPhrase,
                       "December's budget is spent, $100 over counting the $3,100 you started behind.")
    }

    // MARK: - Invariants and precedence

    func testNeededAndPointOfNoReturnAgree() throws {
        let today = date(2026, 11, 10)
        for carry in [Decimal(-500), 0, 400] {
            for step in 0...140 {
                let spent = Decimal(step) * Decimal(string: "37.5")!
                let value = result(input(today: today, carryIn: carry, spent: spent))
                let raw = try XCTUnwrap(Calc.rawNeededDaily(available: 3000 + carry, spent: spent, daysLeft: 20))
                let isLevel3 = value.warning.level == .pointOfNoReturn
                if isLevel3 { XCTAssertTrue(raw < 0, "carry \(carry) spent \(spent)") }
                if raw <= -1 { XCTAssertTrue(isLevel3, "carry \(carry) spent \(spent)") }
                if raw >= 0 { XCTAssertFalse(isLevel3, "carry \(carry) spent \(spent)") }
            }
        }
    }

    func testCarryPointOfNoReturnMeansRecoveryCrossesTheFirstOrNever() throws {
        let today = date(2026, 11, 10)
        for usual in [Decimal(0), 50, 99, 150] {
            for carry in [Decimal(-500), 0, 400] {
                for spent in [Decimal(3001), 3500, 4200, 6000] {
                    let value = result(input(today: today, carryIn: carry, spent: spent, usual: usual))
                    guard value.warning.level == .pointOfNoReturn else { continue }
                    let recovery = try XCTUnwrap(value.recovery)
                    if case .days = recovery.outcome {
                        XCTAssertTrue(recovery.crossesMonth, "usual \(usual) carry \(carry) spent \(spent)")
                    } else {
                        XCTAssertEqual(recovery.outcome, .never)
                    }
                }
            }
        }
    }

    func testHighestLevelWins() {
        let today = date(2026, 11, 10)
        let flat = history(50, days: 90, before: today)
        // Every condition holds: over the month, projected over, needed below the low week.
        XCTAssertEqual(result(input(today: today, spent: 3500, projectedDelta: -900, spentByDay: flat)).warning.level, .pointOfNoReturn)
        XCTAssertEqual(result(input(today: today, spent: 2900, projectedDelta: -900, spentByDay: flat)).warning.level, .hardToRecover)
        XCTAssertEqual(result(input(today: today, spent: 1000, projectedDelta: -900, spentByDay: flat)).warning.level, .trackingOver)
    }

    func testWarningLevelOrderAndRawValuesArePinned() {
        XCTAssertEqual(BudgetWarningLevel.allCases.map(\.rawValue), [0, 1, 2, 3])
        XCTAssertEqual(BudgetWarningLevel.allCases, [.none, .trackingOver, .hardToRecover, .pointOfNoReturn])
        XCTAssertTrue(BudgetWarningLevel.none < .trackingOver)
        XCTAssertTrue(BudgetWarningLevel.trackingOver < .hardToRecover)
        XCTAssertTrue(BudgetWarningLevel.hardToRecover < .pointOfNoReturn)
        XCTAssertEqual([BudgetWarningLevel.pointOfNoReturn, .none, .hardToRecover].max(), .pointOfNoReturn)
    }

    // MARK: - Month lengths and DST

    func testFebruaryLengthsAndThirtyAndThirtyOneDayMonths() {
        // Feb 2028 (29 days) at 2900: base 100; 2 days left from the 27th.
        XCTAssertEqual(outcome(input(today: date(2028, 2, 27), monthly: 2900, boundary: .reset, debt: 100, usual: 50)),
                       .days(2, on: date(2028, 2, 29)))
        // Feb 2027 (28 days) at 2800: 1 day left from the 27th.
        XCTAssertEqual(outcome(input(today: date(2027, 2, 27), monthly: 2800, boundary: .reset, debt: 100, usual: 50)),
                       .resetsOnFirst(date(2027, 3, 1)))
        XCTAssertEqual(Calc.rawNeededDaily(available: 100, spent: 0, daysLeft: 1), 100)
        // 30 vs 31: Nov 20 has 10 days left, Oct 20 has 11.
        XCTAssertEqual(result(input(today: date(2026, 11, 20), spent: 2000)).warning.neededDaily, 100)
        XCTAssertEqual(result(input(today: date(2026, 10, 20), monthly: 3100, spent: 2000)).warning.neededDaily, 100)
    }

    private func zone(_ identifier: String) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: identifier)!
        return cal
    }

    func testSaoPauloMidnightSkippingDST() {
        // 2018-11-04 started at 01:00 in Sao Paulo.
        let cal = zone("America/Sao_Paulo")
        let skipped = cal.startOfDay(for: date(2018, 11, 4, hour: 12, in: cal))
        let saoPauloStart = date(2018, 1, 1, in: cal)
        XCTAssertEqual(cal.component(.hour, from: skipped), 1)

        let today = cal.startOfDay(for: date(2018, 11, 10, hour: 12, in: cal))
        let lookback = history(40, days: 14, before: today, cal: cal)
        XCTAssertNotNil(lookback[skipped])
        XCTAssertEqual(Calc.usualDailySpend(spentByDay: lookback, today: today, budgetStartDay: date(2018, 1, 1, in: cal), schedule: .monthly(3000), calendar: cal), 40)

        let from = cal.startOfDay(for: date(2018, 11, 2, hour: 12, in: cal))
        XCTAssertEqual(outcome(input(today: from, debt: 100, usual: 50, start: saoPauloStart, cal: cal), cal: cal), .days(2, on: skipped))
        XCTAssertEqual(outcome(input(today: from, debt: 150, usual: 50, start: saoPauloStart, cal: cal), cal: cal),
                       .days(3, on: cal.startOfDay(for: date(2018, 11, 5, hour: 12, in: cal))))
        // n = 7 => N = 4: the target horizon Nov 1-4 ends on the skipped-midnight day.
        let crossing = result(input(today: cal.startOfDay(for: date(2018, 10, 31, hour: 12, in: cal)), debt: 350, usual: 50, start: saoPauloStart, cal: cal), cal: cal)
        XCTAssertEqual(crossing.recovery?.target, Calc.Target(daily: 12, days: 4, by: skipped))
    }

    func testNewYorkSpringForwardAndFallBack() {
        let cal = zone("America/New_York")
        func day(_ m: Int, _ d: Int) -> Date { cal.startOfDay(for: date(2026, m, d, hour: 12, in: cal)) }

        // March 8, 2026: clocks spring forward. Mar base 3100 / 31 = 100.
        XCTAssertEqual(outcome(input(today: day(3, 6), monthly: 3100, debt: 200, usual: 50, cal: cal), cal: cal), .days(4, on: day(3, 10)))
        XCTAssertEqual(Calc.usualDailySpend(spentByDay: history(50, days: 14, before: day(3, 16), cal: cal), today: day(3, 16),
                                            budgetStartDay: day(1, 1), schedule: .monthly(3100), calendar: cal), 50)
        XCTAssertEqual(Calc.completedDays(lookback: 14, before: day(3, 16), notBefore: day(1, 1), calendar: cal).count, 14)

        // November 1, 2026: clocks fall back. Oct 31 +46.77, Nov +50/day.
        let fall = result(input(today: day(10, 30), debt: 150, usual: 50, cal: cal), cal: cal)
        XCTAssertEqual(fall.recovery?.outcome, .days(4, on: day(11, 3)))
        XCTAssertEqual(fall.recovery?.crossesMonth, true)
        XCTAssertEqual(Calc.completedDays(lookback: 14, before: day(11, 3), notBefore: day(1, 1), calendar: cal).count, 14)
    }

    // MARK: - Codable

    func testResultRoundTripsThroughCodable() throws {
        let values = [
            result(input(today: date(2026, 11, 10), debt: 300, usual: 40)),
            result(input(today: date(2026, 11, 10), debt: 100, usual: 150)),
            result(input(today: date(2026, 11, 24), boundary: .reset, debt: 300, usual: 90)),
            result(input(today: date(2026, 11, 10), debt: 100, start: date(2026, 11, 5))),
            result(input(today: date(2026, 11, 1), carryIn: -300, spent: 2750)),
            result(input(today: date(2026, 11, 10))),
        ]
        for value in values {
            XCTAssertEqual(try JSONDecoder().decode(Calc.Result.self, from: JSONEncoder().encode(value)), value)
        }
    }

    // MARK: - Banner composition

    func testNoBannerWhenNeitherBehindNorWarned() {
        XCTAssertNil(result(input(today: date(2026, 11, 10))).banner)
    }

    func testBehindWithNoTargetAndNoUsualPaceHasNoBanner() {
        // U unavailable and T < $1 with no warning.
        XCTAssertNil(result(input(today: date(2026, 11, 10), debt: 695, start: date(2026, 11, 5))).banner)
    }

    func testNotBehindShowsTheMonthWarningAlone() {
        let value = result(input(today: date(2026, 11, 10), carryIn: 2000, spent: 1505, projectedDelta: -2180))
        XCTAssertNil(value.recovery)
        XCTAssertEqual(value.banner?.lines.map(\.text), [
            "Heading about $180 over for November, counting the $2,000 carried over. Keep to $174 a day from tomorrow to finish even.",
        ])
        XCTAssertEqual(value.banner?.isDeficit, false)
    }

    func testBehindWithWarningShowsHeadlineThenWarning() {
        let value = result(input(today: date(2026, 11, 10), spent: 3500, usual: 40))
        XCTAssertEqual(value.banner?.lines.count, 2)
        XCTAssertEqual(value.banner?.lines.first?.deficitPhrase, nil)
        XCTAssertEqual(value.banner?.lines.last?.text, "November's budget is spent, $500 over. More spending this month carries into December.")
        XCTAssertEqual(value.banner?.isDeficit, true)
    }

    func testBehindWithoutUsualPaceShowsTargetThenWarning() {
        let value = result(input(today: date(2026, 11, 10), carryIn: -100, spent: 1000, projectedDelta: -50, start: date(2026, 11, 5)))
        XCTAssertEqual(value.recovery?.outcome, .unavailable)
        XCTAssertEqual(value.banner?.lines.map(\.text), [
            "Keep to $85 a day to be back by Tue, Nov 17.",
            "Heading about $150 over for November, counting the $100 you started behind. Keep to $95 a day from tomorrow to finish even.",
        ])
    }

    func testBehindWithHeadlineOnly() {
        XCTAssertEqual(result(input(today: date(2026, 11, 10), debt: 150, usual: 50)).banner?.lines.map(\.text), [
            "At your usual $50 a day, your full $100 limit is back in 3 days (Fri, Nov 13).",
        ])
    }

    // MARK: - Copy

    private func line(_ level: BudgetWarningLevel, carryIn: Decimal, carries: Bool = true, needed: Decimal = 62,
                      heading: Decimal = 180, overBy: Decimal = 50) -> BudgetSummaryCalculator.ProgressSentence? {
        Calc.warningLine(
            Calc.Warning(level: level, neededDaily: needed, lowTypicalDaily: nil, headingOver: heading, overBy: overBy),
            carryIn: carryIn, carries: carries, today: date(2026, 11, 10), nextMonthStart: date(2026, 12, 1), calendar: calendar
        )
    }

    func testTrackingOverCopy() {
        XCTAssertEqual(line(.trackingOver, carryIn: -300)?.text,
                       "Heading about $180 over for November, counting the $300 you started behind. Keep to $62 a day from tomorrow to finish even.")
        XCTAssertEqual(line(.trackingOver, carryIn: 500)?.text,
                       "Heading about $180 over for November, counting the $500 carried over. Keep to $62 a day from tomorrow to finish even.")
        XCTAssertEqual(line(.trackingOver, carryIn: Decimal(string: "0.4")!)?.text,
                       "Heading about $180 over for November. Keep to $62 a day from tomorrow to finish even.")
        XCTAssertEqual(line(.trackingOver, carryIn: -300, carries: false)?.text,
                       "Heading about $180 over for November. Keep to $62 a day from tomorrow to finish on budget.")
        XCTAssertEqual(line(.trackingOver, carryIn: 0, needed: 0)?.text,
                       "Heading about $180 over for November. Keep to less than $1 a day from tomorrow to finish even.")
        XCTAssertNil(line(.trackingOver, carryIn: -300)?.deficitPhrase)
    }

    func testHardToRecoverCopy() {
        let tail = " takes $18 a day, lighter than almost any week you've had lately."
        XCTAssertEqual(line(.hardToRecover, carryIn: 500, needed: 18, heading: 420)?.text,
                       "Heading about $420 over for November, counting the $500 carried over. Finishing even" + tail)
        XCTAssertEqual(line(.hardToRecover, carryIn: -300, needed: 18, heading: 420)?.text,
                       "Heading about $420 over for November, counting the $300 you started behind. Finishing even" + tail)
        XCTAssertEqual(line(.hardToRecover, carryIn: Decimal(string: "-0.3")!, needed: 18, heading: 420)?.text,
                       "Heading about $420 over for November. Finishing even" + tail)
        XCTAssertEqual(line(.hardToRecover, carryIn: 500, carries: false, needed: 18, heading: 420)?.text,
                       "Heading about $420 over for November. Finishing on budget" + tail)
        XCTAssertNil(line(.hardToRecover, carryIn: 500)?.deficitPhrase)
    }

    func testPointOfNoReturnCopyBoldsOnlyTheDeficitPhrase() {
        let carries = " More spending this month carries into December."
        let zero = line(.pointOfNoReturn, carryIn: Decimal(string: "0.4")!)
        XCTAssertEqual(zero?.deficitPhrase, "November's budget is spent, $50 over.")
        XCTAssertEqual(zero?.tail, carries)
        XCTAssertEqual(zero?.lead, "")

        XCTAssertEqual(line(.pointOfNoReturn, carryIn: 500)?.deficitPhrase,
                       "November's budget and the $500 carried over are spent, $50 over.")
        XCTAssertEqual(line(.pointOfNoReturn, carryIn: -300)?.text,
                       "November's budget is spent, $50 over counting the $300 you started behind." + carries)

        let reset = line(.pointOfNoReturn, carryIn: -300, carries: false)
        XCTAssertEqual(reset?.deficitPhrase, "November's budget is spent.")
        XCTAssertEqual(reset?.text, "November's budget is spent. It starts fresh on Dec 1.")
        XCTAssertNil(line(.none, carryIn: 0))
    }

    func testCarryClause() {
        XCTAssertEqual(Calc.carryClause(500), " counting the $500 carried over")
        XCTAssertEqual(Calc.carryClause(-300), " counting the $300 you started behind")
        XCTAssertEqual(Calc.carryClause(Decimal(string: "0.49")!), "")
        XCTAssertEqual(Calc.carryClause(Decimal(string: "-0.49")!), "")
        XCTAssertEqual(Calc.carryClause(Decimal(string: "0.5")!), " counting the $1 carried over")
    }

    func testResetHeadlineAndTargetCopyThroughInsights() throws {
        // Reset mode, Nov 2026 base 100: 14 days at 90 then $400 today on the 24th.
        let b = budget(start: date(2026, 11, 1), carries: false)
        var t = (10...23).map { txn(90, date(2026, 11, $0)) }
        t.append(txn(1000, date(2026, 11, 24)))
        let value = try insights(b, t, on: date(2026, 11, 24))
        // Spent 2260 of 2400 budgeted: reset-mode remaining = paceDelta = 140, not behind.
        XCTAssertNil(value.recovery.recovery)
        XCTAssertEqual(value.recovery.carryIn, 0)

        t.append(txn(500, date(2026, 11, 24)))
        let behind = try insights(b, t, on: date(2026, 11, 24))
        XCTAssertEqual(behind.recovery.recovery?.debt, 360)
        XCTAssertEqual(behind.recovery.banner?.lines.first?.text,
                       "At your usual $90 a day, you'll still be behind when your limit resets on the 1st.")
    }

    func testDateCopyIsEnUS() {
        XCTAssertEqual(Calc.weekdayMonthDay(date(2026, 11, 28), calendar: calendar), "Sat, Nov 28")
        XCTAssertEqual(Calc.monthName(date(2026, 11, 28), calendar: calendar), "November")
    }
}

// MARK: - Tester additions (reservoir-nka.1 verification)

extension BudgetRecoveryCalculatorTests {

    func testLowTypicalIgnoresDaysOlderThanTheNinetyDayLookback() {
        // 90 days at 50 inside the lookback; days 91-150 back are zero. Were they counted, the
        // rolling weeks of zeros would pull P10 down to 0.
        let today = date(2026, 11, 10)
        var days = history(50, days: 90, before: today)
        let noon = calendar.date(byAdding: .hour, value: 12, to: today)!
        for back in 91...150 {
            days[calendar.startOfDay(for: calendar.date(byAdding: .day, value: -back, to: noon)!)] = 0
        }
        XCTAssertEqual(
            Calc.lowTypicalDailySpend(spentByDay: days, today: today, budgetStartDay: date(2025, 1, 1), calendar: calendar),
            50
        )
        XCTAssertEqual(Calc.completedDays(lookback: 90, before: today, notBefore: date(2025, 1, 1), calendar: calendar).count, 90)
    }

    func testUsualPaceCapUsesEachDaysOwnBaseAcrossAMonthBoundary() {
        // 3100/month: Oct base 100 (cap 200), Nov base 103.33 (cap 206.67).
        let today = date(2026, 11, 5)
        let days: [Date: Decimal] = [date(2026, 10, 31): 1000, date(2026, 11, 2): 1000]
        let usualDaily = try? XCTUnwrap(Calc.usualDailySpend(
            spentByDay: days, today: today, budgetStartDay: date(2025, 1, 1), schedule: .monthly(3100), calendar: calendar
        ))
        var total = (usualDaily ?? 0) * 14
        var rounded = Decimal()
        NSDecimalRound(&rounded, &total, 2, .plain)
        XCTAssertEqual(rounded, Decimal(string: "406.67")!)
    }

    func testPointOfNoReturnOnTheFirstDayOfAFreshBudget() throws {
        // Mirrors the budgetPointOfNoReturn UI scenario when it runs on the 1st: no history, so
        // no usual pace and no reachable target; the banner is the level-3 line alone.
        let b = budget(start: date(2026, 12, 1))
        let value = try insights(b, [txn(3500, date(2026, 12, 1, hour: 10))], on: date(2026, 12, 1, hour: 15))
        XCTAssertEqual(value.recovery.carryIn, 0)
        XCTAssertEqual(value.recovery.recovery?.outcome, .unavailable)
        XCTAssertNil(value.recovery.recovery?.target)
        XCTAssertEqual(value.recovery.warning.level, .pointOfNoReturn)
        XCTAssertEqual(value.recovery.warning.overBy, 500)
        XCTAssertEqual(value.recovery.banner?.lines.map(\.text), [
            "December's budget is spent, $500 over. More spending this month carries into January.",
        ])
        XCTAssertEqual(value.recovery.banner?.isDeficit, true)
    }

    func testPointOfNoReturnScenarioOnTheLastDayOfTheMonth() throws {
        // Same scenario on the 30th: 29 zero days give a usual pace of $0, recovery crosses the 1st.
        let b = budget(start: date(2026, 11, 1))
        let value = try insights(b, [txn(3500, date(2026, 11, 30, hour: 10))], on: date(2026, 11, 30, hour: 15))
        XCTAssertEqual(value.recovery.warning.level, .pointOfNoReturn)
        let recovery = try XCTUnwrap(value.recovery.recovery)
        XCTAssertEqual(recovery.debt, 500)
        XCTAssertEqual(recovery.usualDaily, 0)
        // Dec base 96.77: 5 days = 483.87, 6 days = 580.65.
        XCTAssertEqual(recovery.outcome, .days(6, on: date(2026, 12, 6)))
        XCTAssertTrue(recovery.crossesMonth)
        XCTAssertEqual(value.recovery.banner?.lines.count, 2)
    }

    func testResetModeLastDayWithoutUsualPaceHasNoTarget() {
        let value = result(input(today: date(2026, 11, 30), boundary: .reset, debt: 50, start: date(2026, 11, 25)))
        XCTAssertEqual(value.recovery?.outcome, .unavailable)
        XCTAssertNil(value.recovery?.target)
        XCTAssertNil(value.banner)
    }

    func testSaoPauloLookbackStartingOnTheSkippedMidnight() {
        // 14 days before Nov 18, 2018 is Nov 4, whose day starts at 01:00 in Sao Paulo. The
        // window must start there, not slip back to Nov 3 and count 15 days.
        let cal = zone("America/Sao_Paulo")
        let today = cal.startOfDay(for: date(2018, 11, 18, hour: 12, in: cal))
        let skipped = cal.startOfDay(for: date(2018, 11, 4, hour: 12, in: cal))
        let days = Calc.completedDays(lookback: 14, before: today, notBefore: date(2018, 1, 1, in: cal), calendar: cal)
        XCTAssertEqual(days.count, 14)
        XCTAssertEqual(days.first, skipped)

        var spend = history(40, days: 14, before: today, cal: cal)
        spend[cal.startOfDay(for: date(2018, 11, 3, hour: 12, in: cal))] = 1000
        XCTAssertEqual(Calc.usualDailySpend(spentByDay: spend, today: today, budgetStartDay: date(2018, 1, 1, in: cal),
                                            schedule: .monthly(3000), calendar: cal), 40)
    }
}
