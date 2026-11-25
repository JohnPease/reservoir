import XCTest
import SwiftData
@testable import Reservoir

/// reservoir-nka.1: the no-spend days until the full daily limit is back, month warnings and the
/// Today banner. Most cases drive the pure `BudgetRecoveryCalculator.result` with hand-built inputs; a
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

    /// A consistent input for `today`: `paceDelta = budgeted - spent`, where `budgeted` is the
    /// month's bases through today. `remaining` is `-debt` when `debt` is given, else
    /// `carryIn + paceDelta` (carry) / `paceDelta` (reset).
    private func input(
        today: Date,
        monthly: Decimal = 3000,
        boundary: MonthBoundary = .carry,
        carryIn: Decimal = 0,
        spent: Decimal = 0,
        windowBudget: Decimal? = nil,
        projectedDelta: Decimal? = nil,
        debt: Decimal? = nil,
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
            paceDelta: paceDelta,
            projectedDelta: projectedDelta,
            dayOfMonth: dayOfMonth,
            daysInMonth: daysInMonth,
            spentByDay: spentByDay ?? [:],
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

    private func insights(
        _ budget: Budget, _ transactions: [SpendTransaction], on day: Date, includeRecovery: Bool = true
    ) throws -> BudgetSummaryCalculator.BudgetInsights {
        try XCTUnwrap(BudgetSummaryCalculator.insights(
            budget: budget, transactions: transactions, isAccountBackfillComplete: true,
            referenceDate: day, linkedAccounts: [], linkedItems: [], includeRecovery: includeRecovery, calendar: calendar
        ))
    }

    /// The recovery result through `insights` (opted in, as Today does).
    private func recoveryResult(_ budget: Budget, _ transactions: [SpendTransaction], on day: Date) throws -> Calc.Result {
        try XCTUnwrap(try insights(budget, transactions, on: day).recovery)
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
            let value = try recoveryResult(b, all, on: date(2026, 10, 9))
            XCTAssertEqual(value.carryIn, walkedCarry(b, all, into: date(2026, 10, 1)), name)
        }
    }

    func testCarryInSigns() throws {
        let b = budget(monthly: 3100, start: date(2026, 9, 1))
        XCTAssertEqual(try recoveryResult(b, [txn(1000, date(2026, 9, 10))], on: date(2026, 10, 9)).carryIn, 2100)
        let over = budget(monthly: 3100, start: date(2026, 9, 1))
        XCTAssertEqual(try recoveryResult(over, [txn(3600, date(2026, 9, 10))], on: date(2026, 10, 9)).carryIn, -500)
    }

    func testCarryInIsZeroWhenTheBudgetStartedThisMonthOrResets() throws {
        let fresh = budget(start: date(2026, 11, 5))
        let t = [txn(900, date(2026, 11, 6))]
        XCTAssertEqual(try recoveryResult(fresh, t, on: date(2026, 11, 10)).carryIn, 0)

        let reset = budget(start: date(2026, 9, 1), carries: false)
        XCTAssertEqual(try recoveryResult(reset, [txn(9000, date(2026, 10, 10))], on: date(2026, 11, 10)).carryIn, 0)
        XCTAssertEqual(Calc.carryIn(remaining: -50, paceDelta: 20, boundary: .reset), 0)
        XCTAssertEqual(Calc.carryIn(remaining: -50, paceDelta: 20, boundary: .carry), -70)
    }

    // MARK: - Debt

    func testDebtThresholdIsOneDollar() {
        XCTAssertNil(result(input(today: date(2026, 11, 10), debt: Decimal(string: "0.99")!)).recovery)
        let owed = result(input(today: date(2026, 11, 10), debt: 1)).recovery
        XCTAssertEqual(owed?.debt, 1)
    }

    func testTodaysSpendCreatesDebtWhileCarryIsPositive() throws {
        // Nov base 100; $90 a day banks +$90 by the 10th, then $300 today: remaining = 190 - 300.
        let b = budget(start: date(2026, 11, 1))
        let t = (1...9).map { txn(90, date(2026, 11, $0)) } + [txn(300, date(2026, 11, 10))]
        let summary = try XCTUnwrap(BudgetCalculator.summary(budget: b, allTransactions: t, referenceDate: date(2026, 11, 10), calendar: calendar))
        XCTAssertEqual(summary.carriedForward, 90)
        let recovery = try XCTUnwrap(try recoveryResult(b, t, on: date(2026, 11, 10)).recovery)
        XCTAssertEqual(recovery.debt, -summary.remaining)
        XCTAssertEqual(recovery.debt, 110)
    }

    // MARK: - Counted spend and opt-in

    func testCountedSpendByDayIgnoresFixedAndUnselectedAccounts() {
        let b = budget(start: date(2026, 11, 1))
        let t = [
            txn(30, date(2026, 11, 2, hour: 9)), txn(20, date(2026, 11, 2, hour: 18)),
            txn(50, date(2026, 11, 2), type: .fixed), txn(70, date(2026, 11, 2), account: "other"),
            txn(90, date(2026, 10, 30)),
        ]
        XCTAssertEqual(BudgetCalculator.countedSpendByDay(t, for: b, calendar: calendar), [date(2026, 11, 2): 50])
        // The already-counted overload buckets exactly the same list without filtering again.
        let counted = BudgetCalculator.countingTransactions(t, for: b, calendar: calendar)
        XCTAssertEqual(BudgetCalculator.countedSpendByDay(counted: counted, calendar: calendar), [date(2026, 11, 2): 50])
        XCTAssertEqual(BudgetCalculator.countedSpendByDay(counted: t, calendar: calendar)[date(2026, 11, 2)], 170)
    }

    func testRecoveryIsOptInButTheCarryAwareProjectionIsNot() throws {
        // Sep overspent by 300 (C = -300); Oct 100/day through the 8th.
        let b = budget(monthly: 3100, start: date(2026, 9, 1))
        let t = [txn(3400, date(2026, 9, 10))] + (1...8).map { txn(100, date(2026, 10, $0)) }
        let plain = try insights(b, t, on: date(2026, 10, 8), includeRecovery: false)
        XCTAssertNil(plain.recovery)
        XCTAssertEqual(plain.projection?.carryIn, -300)
        let defaulted = try XCTUnwrap(BudgetSummaryCalculator.insights(
            budget: b, transactions: t, isAccountBackfillComplete: true, referenceDate: date(2026, 10, 8),
            linkedAccounts: [], linkedItems: [], calendar: calendar
        ))
        XCTAssertNil(defaulted.recovery)
        let opted = try insights(b, t, on: date(2026, 10, 8))
        XCTAssertEqual(opted.recovery?.carryIn, -300)
        XCTAssertEqual(opted.projection, plain.projection)
    }

    // MARK: - Recovery

    private func outcome(_ input: Calc.Input, cal: Calendar? = nil) -> Calc.Outcome? {
        result(input, cal: cal).recovery?.outcome
    }

    func testNoSpendDaysAreTheFewestBasesThatCoverTheDebt() {
        // Nov base 100: 300 takes Nov 11-13, so the full limit is back Nov 14.
        let today = date(2026, 11, 10)
        XCTAssertEqual(outcome(input(today: today, debt: 300)), .noSpend(days: 3, backOn: date(2026, 11, 14)))
        XCTAssertEqual(outcome(input(today: today, debt: 301)), .noSpend(days: 4, backOn: date(2026, 11, 15)))
        XCTAssertEqual(outcome(input(today: today, debt: 1)), .noSpend(days: 1, backOn: date(2026, 11, 12)))
        XCTAssertEqual(result(input(today: today, debt: 300)).banner?.lines.first?.text,
                       "3 no-spend days from tomorrow get your full $100 limit back on Sat, Nov 14.")
        XCTAssertEqual(result(input(today: today, debt: 50)).banner?.lines.first?.text,
                       "1 no-spend day (tomorrow) gets your full $100 limit back on Thu, Nov 12.")
    }

    func testCarryCountRunsIntoTheNextMonthAtItsBase() {
        // Nov 29-30 give 200, Dec 1 96.77 (296.77), Dec 2 covers 300 => back Dec 3 at $97.
        let value = result(input(today: date(2026, 11, 28), debt: 300))
        XCTAssertEqual(value.recovery?.outcome, .noSpend(days: 4, backOn: date(2026, 12, 3)))
        XCTAssertEqual(value.banner?.lines.first?.text, "4 no-spend days from tomorrow get your full $97 limit back on Thu, Dec 3.")
        // December into January: Dec 31 + Jan 1 => back Jan 2.
        XCTAssertEqual(outcome(input(today: date(2026, 12, 30), debt: 150)), .noSpend(days: 2, backOn: date(2027, 1, 2)))
    }

    func testResetModeSaysTheResetClearsItWhenTheCountRunsPastTheMonth() {
        let today = date(2026, 11, 24) // 6 days left
        // 500 is covered by Nov 25-29: back Nov 30, inside the month.
        XCTAssertEqual(outcome(input(today: today, boundary: .reset, debt: 500)), .noSpend(days: 5, backOn: date(2026, 11, 30)))
        // 600 needs every day left, so the limit would be back Dec 1: the reset clears it first.
        XCTAssertEqual(outcome(input(today: today, boundary: .reset, debt: 600)), .resetClears(days: 6, resetsOn: date(2026, 12, 1)))
        XCTAssertEqual(outcome(input(today: today, debt: 600)), .noSpend(days: 6, backOn: date(2026, 12, 1)))
        // 700 would take Dec 1-2 too (bases follow the schedule past the 1st).
        let value = result(input(today: today, boundary: .reset, debt: 700))
        XCTAssertEqual(value.recovery?.outcome, .resetClears(days: 8, resetsOn: date(2026, 12, 1)))
        XCTAssertEqual(value.banner?.lines.first?.text, "You'd need 8 no-spend days to catch up, but your limit resets to full on Dec 1.")
    }

    func testResetModeOnTheLastDayResetsTomorrow() {
        let value = result(input(today: date(2026, 11, 30), boundary: .reset, debt: 50))
        XCTAssertEqual(value.recovery?.outcome, .resetClears(days: 1, resetsOn: date(2026, 12, 1)))
        XCTAssertEqual(value.banner?.lines.first?.text, "You'd need 1 no-spend day to catch up, but your limit resets to full tomorrow.")
    }

    func testZeroBudgetHasNoRecovery() {
        let value = result(input(today: date(2026, 11, 10), monthly: 0, debt: 50))
        XCTAssertNil(value.recovery)
        // The month warning still shows; there's just no daily-limit section.
        XCTAssertEqual(value.banner?.sections.map(\.kind), [.month])
    }

    func testNoSpendDaysThroughInsights() throws {
        // Started the 20th (limit 100), $400 today: 300 behind => Nov 21-23, back Nov 24.
        let b = budget(start: date(2026, 11, 20))
        let value = try recoveryResult(b, [txn(400, date(2026, 11, 20, hour: 9))], on: date(2026, 11, 20, hour: 15))
        XCTAssertEqual(value.recovery?.debt, 300)
        XCTAssertEqual(value.recovery?.outcome, .noSpend(days: 3, backOn: date(2026, 11, 24)))
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
        // available 3000 - 300 = 2700; (2700 - 1505) / 20 days left = 59.75, kept unrounded and
        // rounded down in the copy.
        let value = result(input(today: date(2026, 11, 10), carryIn: -300, spent: 1505, projectedDelta: 120))
        XCTAssertEqual(value.warning.level, .trackingOver)
        XCTAssertEqual(value.warning.headingOver, 180)
        XCTAssertEqual(value.warning.neededDaily, Decimal(string: "59.75")!)
        XCTAssertEqual(value.banner?.lines.last?.text,
                       "Heading about $180 over, counting the $300 you started behind. Keep to $59 a day from tomorrow to finish even.")
    }

    func testTrackingOverNeedsSevenCompletedDaysThroughInsights() throws {
        let b = budget(monthly: 3100, start: date(2026, 10, 1))
        let t = (1...8).map { txn(150, date(2026, 10, $0)) }
        XCTAssertEqual(try recoveryResult(b, t, on: date(2026, 10, 7)).warning.level, .none)
        let eighth = try recoveryResult(b, t, on: date(2026, 10, 8))
        XCTAssertEqual(eighth.warning.level, .trackingOver)
        // Projected 4650 against 3100: $1,550 over; (3100 - 1200) / 23 = 82.6 => $82.
        XCTAssertEqual(eighth.banner?.lines.last?.text,
                       "Heading about $1,550 over. Keep to $82 a day from tomorrow to finish even.")
    }

    func testTrackingOverForAMidMonthStart() throws {
        let b = budget(monthly: 3100, start: date(2026, 10, 10))
        let t = (10...17).map { txn(150, date(2026, 10, $0)) }
        XCTAssertEqual(try recoveryResult(b, t, on: date(2026, 10, 16)).warning.level, .none)
        let warning = try recoveryResult(b, t, on: date(2026, 10, 17)).warning
        XCTAssertEqual(warning.level, .trackingOver)
        // Window 2200; projected 1200 + 150 * 14 = 3300 => 1100 over.
        XCTAssertEqual(warning.headingOver, 1100)
    }

    func testTrackingOverHiddenOnTheLastDay() throws {
        let b = budget(monthly: 3100, start: date(2026, 10, 1))
        let t = (1...30).map { txn(101, date(2026, 10, $0)) }
        XCTAssertNotEqual(try recoveryResult(b, t, on: date(2026, 10, 30)).warning.level, .none)
        let last = try recoveryResult(b, t, on: date(2026, 10, 31)).warning
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

    func testLowTypicalIsOnlyComputedOnceTrackingOverHolds() {
        let today = date(2026, 11, 10)
        let flat = history(50, days: 90, before: today)
        XCTAssertNil(result(input(today: today, spent: 2900, projectedDelta: 10, spentByDay: flat)).warning.lowTypicalDaily)
        XCTAssertNil(result(input(today: today, spent: 3500, projectedDelta: -900, spentByDay: flat)).warning.lowTypicalDaily)
        XCTAssertEqual(result(input(today: today, spent: 1000, projectedDelta: -900, spentByDay: flat)).warning.lowTypicalDaily, 50)
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
        XCTAssertEqual(try recoveryResult(b, t, on: date(2026, 10, 2)).warning.level, .pointOfNoReturn)
        let last = try recoveryResult(b, t, on: date(2026, 10, 31)).warning
        XCTAssertEqual(last.level, .pointOfNoReturn)
        XCTAssertEqual(last.overBy, 100)
    }

    func testPointOfNoReturnForAProratedMidMonthStart() throws {
        let b = budget(monthly: 3100, start: date(2026, 10, 12))
        let warning = try recoveryResult(b, [txn(2100, date(2026, 10, 13))], on: date(2026, 10, 14)).warning
        XCTAssertEqual(warning.level, .pointOfNoReturn)
        XCTAssertEqual(warning.overBy, 100)
    }

    func testPointOfNoReturnOnTheFirstWithHugeCarriedInDebt() throws {
        let b = budget(start: date(2026, 11, 1))
        let value = try recoveryResult(b, [txn(6100, date(2026, 11, 20))], on: date(2026, 12, 1))
        XCTAssertEqual(value.carryIn, -3100)
        XCTAssertEqual(value.warning.level, .pointOfNoReturn)
        XCTAssertEqual(value.warning.overBy, 100)
        // 3003.23 behind (Dec 1's base is in): Dec 2-31 and Jan 1-2 => back Jan 3.
        XCTAssertEqual(value.banner?.lines.map(\.text), [
            "32 no-spend days from tomorrow get your full $97 limit back on Sun, Jan 3.",
            "December's budget can't cover the $3,100 you started behind, $100 over. More spending this month carries into January.",
        ])
        XCTAssertEqual(value.banner?.lines.last?.deficitPhrase,
                       "December's budget can't cover the $3,100 you started behind, $100 over.")
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

    func testCarryPointOfNoReturnMeansTheCountCrossesTheFirst() throws {
        // Over the month by >= $1 means the rest of the month's bases can't cover the debt.
        let today = date(2026, 11, 10)
        for carry in [Decimal(-500), 0, 400] {
            for spent in [Decimal(3001), 3500, 4200, 6000] {
                let value = result(input(today: today, carryIn: carry, spent: spent))
                guard value.warning.level == .pointOfNoReturn else { continue }
                guard case .noSpend(_, let backOn) = try XCTUnwrap(value.recovery).outcome else {
                    return XCTFail("carry \(carry) spent \(spent)")
                }
                XCTAssertGreaterThan(backOn, date(2026, 12, 1), "carry \(carry) spent \(spent)")
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
        XCTAssertEqual(outcome(input(today: date(2028, 2, 27), monthly: 2900, boundary: .reset, debt: 100)),
                       .noSpend(days: 1, backOn: date(2028, 2, 29)))
        XCTAssertEqual(outcome(input(today: date(2028, 2, 27), monthly: 2900, boundary: .reset, debt: 150)),
                       .resetClears(days: 2, resetsOn: date(2028, 3, 1)))
        // Feb 2027 (28 days) at 2800: 1 day left from the 27th.
        XCTAssertEqual(outcome(input(today: date(2027, 2, 27), monthly: 2800, boundary: .reset, debt: 100)),
                       .resetClears(days: 1, resetsOn: date(2027, 3, 1)))
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

        let from = cal.startOfDay(for: date(2018, 11, 2, hour: 12, in: cal))
        // One no-spend day (Nov 3) => back on the skipped-midnight day.
        XCTAssertEqual(outcome(input(today: from, debt: 50, start: saoPauloStart, cal: cal), cal: cal), .noSpend(days: 1, backOn: skipped))
        // Through the skipped day => back Nov 5.
        XCTAssertEqual(outcome(input(today: from, debt: 150, start: saoPauloStart, cal: cal), cal: cal),
                       .noSpend(days: 2, backOn: cal.startOfDay(for: date(2018, 11, 5, hour: 12, in: cal))))
    }

    func testNewYorkSpringForwardAndFallBack() {
        let cal = zone("America/New_York")
        func day(_ m: Int, _ d: Int) -> Date { cal.startOfDay(for: date(2026, m, d, hour: 12, in: cal)) }

        // March 8, 2026: clocks spring forward. Mar base 3100 / 31 = 100.
        XCTAssertEqual(outcome(input(today: day(3, 6), monthly: 3100, debt: 200, cal: cal), cal: cal), .noSpend(days: 2, backOn: day(3, 9)))
        XCTAssertEqual(Calc.completedDays(lookback: 14, before: day(3, 16), notBefore: day(1, 1), calendar: cal).count, 14)

        // November 1, 2026: clocks fall back. Oct 31 96.77 + Nov 1 100 covers 150.
        XCTAssertEqual(outcome(input(today: day(10, 30), debt: 150, cal: cal), cal: cal), .noSpend(days: 2, backOn: day(11, 2)))
        XCTAssertEqual(Calc.completedDays(lookback: 14, before: day(11, 3), notBefore: day(1, 1), calendar: cal).count, 14)
    }

    // MARK: - Codable

    func testResultRoundTripsThroughCodable() throws {
        let values = [
            result(input(today: date(2026, 11, 10), debt: 300)),
            result(input(today: date(2026, 11, 10), debt: 100)),
            result(input(today: date(2026, 11, 24), boundary: .reset, debt: 700)),
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

    func testNotBehindShowsTheMonthWarningAlone() {
        let value = result(input(today: date(2026, 11, 10), carryIn: 2000, spent: 1505, projectedDelta: -2180))
        XCTAssertNil(value.recovery)
        let section = try? XCTUnwrap(value.banner?.sections.first)
        XCTAssertEqual(value.banner?.sections.count, 1)
        XCTAssertEqual(section?.kind, .month)
        XCTAssertEqual(section?.title, "November budget")
        XCTAssertEqual(section?.status, "Tracking over")
        XCTAssertEqual(section?.level, .trackingOver)
        XCTAssertEqual(section?.sentence.text,
                       "Heading about $180 over, counting the $2,000 carried over. Keep to $174 a day from tomorrow to finish even.")
        XCTAssertEqual(value.banner?.isDeficit, false)
    }

    func testBehindWithWarningShowsHeadlineThenWarning() {
        // 2500 behind: Nov 11-30 give 2000, Dec 1-6 the rest => back Dec 7.
        let value = result(input(today: date(2026, 11, 10), spent: 3500))
        XCTAssertEqual(value.recovery?.outcome, .noSpend(days: 26, backOn: date(2026, 12, 7)))
        XCTAssertEqual(value.banner?.sections.map(\.kind), [.dailyLimit, .month])
        XCTAssertEqual(value.banner?.sections.map(\.status), [nil, "Over budget"])
        XCTAssertEqual(value.banner?.sections.map(\.level), [nil, .pointOfNoReturn])
        XCTAssertEqual(value.banner?.lines.first?.deficitPhrase, nil)
        XCTAssertEqual(value.banner?.lines.last?.text, "November's budget is spent, $500 over. More spending this month carries into December.")
        XCTAssertEqual(value.banner?.isDeficit, true)
    }

    func testBehindAndTrackingOverShowsBothSections() {
        let value = result(input(today: date(2026, 11, 10), carryIn: -100, spent: 1000, projectedDelta: -50))
        XCTAssertEqual(value.recovery?.outcome, .noSpend(days: 1, backOn: date(2026, 11, 12)))
        XCTAssertEqual(value.banner?.lines.map(\.text), [
            "1 no-spend day (tomorrow) gets your full $100 limit back on Thu, Nov 12.",
            "Heading about $150 over, counting the $100 you started behind. Keep to $95 a day from tomorrow to finish even.",
        ])
        XCTAssertEqual(value.banner?.accessibilityText,
                       "Daily limit. 1 no-spend day (tomorrow) gets your full $100 limit back on Thu, Nov 12. "
                       + "November budget, Tracking over. Heading about $150 over, counting the $100 you started behind. "
                       + "Keep to $95 a day from tomorrow to finish even.")
    }

    func testBehindAloneShowsTheDailyLimitSection() {
        let banner = result(input(today: date(2026, 11, 10), debt: 150)).banner
        XCTAssertEqual(banner?.sections.map(\.title), ["Daily limit"])
        XCTAssertEqual(banner?.lines.map(\.text), ["2 no-spend days from tomorrow get your full $100 limit back on Fri, Nov 13."])
    }

    func testWarningStatuses() {
        XCTAssertNil(Calc.status(.none))
        XCTAssertEqual(Calc.status(.trackingOver), "Tracking over")
        XCTAssertEqual(Calc.status(.hardToRecover), "Hard to recover")
        XCTAssertEqual(Calc.status(.pointOfNoReturn), "Over budget")
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
                       "Heading about $180 over, counting the $300 you started behind. Keep to $62 a day from tomorrow to finish even.")
        XCTAssertEqual(line(.trackingOver, carryIn: 500)?.text,
                       "Heading about $180 over, counting the $500 carried over. Keep to $62 a day from tomorrow to finish even.")
        XCTAssertEqual(line(.trackingOver, carryIn: Decimal(string: "0.4")!)?.text,
                       "Heading about $180 over. Keep to $62 a day from tomorrow to finish even.")
        // Reset mode always has C = 0.
        XCTAssertEqual(line(.trackingOver, carryIn: 0, carries: false)?.text,
                       "Heading about $180 over. Keep to $62 a day from tomorrow to finish on budget.")
        XCTAssertEqual(line(.trackingOver, carryIn: 0, needed: Decimal(string: "62.9")!)?.text,
                       "Heading about $180 over. Keep to $62 a day from tomorrow to finish even.")
        XCTAssertEqual(line(.trackingOver, carryIn: 0, needed: 1)?.text,
                       "Heading about $180 over. Keep to $1 a day from tomorrow to finish even.")
    }

    func testNeededUnderADollarOrNothingLeftCopy() {
        // 0 < needed < $1: "under $1", never "less than $1" or "$0".
        XCTAssertEqual(line(.trackingOver, carryIn: -300, needed: Decimal(string: "0.5")!)?.text,
                       "Heading about $180 over, counting the $300 you started behind. Keep to under $1 a day from tomorrow to finish even.")
        XCTAssertEqual(line(.hardToRecover, carryIn: 0, needed: Decimal(string: "0.5")!)?.text,
                       "Heading about $180 over. Finishing even takes under $1 a day, lighter than almost any week you've had lately.")
        // needed <= 0 within the $1 tolerance of level 3: finishing even means no more spending.
        let none = "Heading about $180 over, counting the $300 you started behind. Finishing even means no more spending this month."
        XCTAssertEqual(line(.trackingOver, carryIn: -300, needed: 0)?.text, none)
        XCTAssertEqual(line(.trackingOver, carryIn: -300, needed: Decimal(string: "-0.04")!)?.text, none)
        XCTAssertEqual(line(.hardToRecover, carryIn: -300, needed: Decimal(string: "-0.04")!)?.text, none)
        XCTAssertEqual(line(.trackingOver, carryIn: 0, carries: false, needed: 0)?.text,
                       "Heading about $180 over. Finishing on budget means no more spending this month.")
        XCTAssertEqual(line(.hardToRecover, carryIn: 0, carries: false, needed: Decimal(string: "-0.5")!)?.text,
                       "Heading about $180 over. Finishing on budget means no more spending this month.")
    }

    func testNeededWithinTheToleranceOfLevelThreeThroughResult() throws {
        // Spent 3000.50 of 3000 (under the $1 level-3 threshold), projected over: raw need < 0,
        // below the all-zero history's $0 low week, so hard to recover; same sentence either way.
        let value = result(input(today: date(2026, 11, 10), spent: Decimal(string: "3000.5")!, projectedDelta: -600))
        XCTAssertEqual(value.warning.level, .hardToRecover)
        XCTAssertLessThan(try XCTUnwrap(value.warning.neededDaily), 0)
        XCTAssertEqual(value.banner?.lines.last?.text,
                       "Heading about $600 over. Finishing even means no more spending this month.")
        // Spent 2990 => (3000 - 2990) / 20 = 0.50 a day.
        XCTAssertEqual(result(input(today: date(2026, 11, 10), spent: 2990, projectedDelta: -600)).banner?.lines.last?.text,
                       "Heading about $600 over. Keep to under $1 a day from tomorrow to finish even.")
        XCTAssertNil(line(.trackingOver, carryIn: -300)?.deficitPhrase)
    }

    func testHardToRecoverCopy() {
        let tail = " takes $18 a day, lighter than almost any week you've had lately."
        XCTAssertEqual(line(.hardToRecover, carryIn: 500, needed: 18, heading: 420)?.text,
                       "Heading about $420 over, counting the $500 carried over. Finishing even" + tail)
        XCTAssertEqual(line(.hardToRecover, carryIn: -300, needed: 18, heading: 420)?.text,
                       "Heading about $420 over, counting the $300 you started behind. Finishing even" + tail)
        XCTAssertEqual(line(.hardToRecover, carryIn: Decimal(string: "-0.3")!, needed: 18, heading: 420)?.text,
                       "Heading about $420 over. Finishing even" + tail)
        XCTAssertEqual(line(.hardToRecover, carryIn: 0, carries: false, needed: 18, heading: 420)?.text,
                       "Heading about $420 over. Finishing on budget" + tail)
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
        let behind = line(.pointOfNoReturn, carryIn: -300)
        XCTAssertEqual(behind?.deficitPhrase, "November's budget can't cover the $300 you started behind, $50 over.")
        XCTAssertEqual(behind?.text, "November's budget can't cover the $300 you started behind, $50 over." + carries)

        let reset = line(.pointOfNoReturn, carryIn: 0, carries: false)
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

    func testResetRecoveryCopyThroughInsights() throws {
        // Reset mode, Nov 2026 base 100: 14 days at 90 then $400 today on the 24th.
        let b = budget(start: date(2026, 11, 1), carries: false)
        var t = (10...23).map { txn(90, date(2026, 11, $0)) }
        t.append(txn(1000, date(2026, 11, 24)))
        let value = try recoveryResult(b, t, on: date(2026, 11, 24))
        // Spent 2260 of 2400 budgeted: reset-mode remaining = paceDelta = 140, not behind.
        XCTAssertNil(value.recovery)
        XCTAssertEqual(value.carryIn, 0)

        t.append(txn(500, date(2026, 11, 24)))
        let behind = try recoveryResult(b, t, on: date(2026, 11, 24))
        XCTAssertEqual(behind.recovery?.debt, 360)
        // 360 behind: Nov 25-28 => back Nov 29, inside the month.
        XCTAssertEqual(behind.banner?.lines.first?.text,
                       "4 no-spend days from tomorrow get your full $100 limit back on Sun, Nov 29.")
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

    func testPointOfNoReturnOnTheFirstDayOfAFreshBudget() throws {
        // Mirrors the budgetPointOfNoReturn UI scenario when it runs on the 1st: 3403.23 behind,
        // Dec 2-31 and Jan 1-6 => back Jan 7.
        let b = budget(start: date(2026, 12, 1))
        let value = try recoveryResult(b, [txn(3500, date(2026, 12, 1, hour: 10))], on: date(2026, 12, 1, hour: 15))
        XCTAssertEqual(value.carryIn, 0)
        XCTAssertEqual(value.recovery?.outcome, .noSpend(days: 36, backOn: date(2027, 1, 7)))
        XCTAssertEqual(value.warning.level, .pointOfNoReturn)
        XCTAssertEqual(value.warning.overBy, 500)
        XCTAssertEqual(value.banner?.lines.map(\.text), [
            "36 no-spend days from tomorrow get your full $97 limit back on Thu, Jan 7.",
            "December's budget is spent, $500 over. More spending this month carries into January.",
        ])
        XCTAssertEqual(value.banner?.isDeficit, true)
    }

    func testPointOfNoReturnScenarioOnTheLastDayOfTheMonth() throws {
        // Same scenario on the 30th: 500 behind, Dec 1-6 => back Dec 7.
        let b = budget(start: date(2026, 11, 1))
        let value = try recoveryResult(b, [txn(3500, date(2026, 11, 30, hour: 10))], on: date(2026, 11, 30, hour: 15))
        XCTAssertEqual(value.warning.level, .pointOfNoReturn)
        let recovery = try XCTUnwrap(value.recovery)
        XCTAssertEqual(recovery.debt, 500)
        XCTAssertEqual(recovery.outcome, .noSpend(days: 6, backOn: date(2026, 12, 7)))
        XCTAssertEqual(value.banner?.lines.count, 2)
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
    }
}
