import XCTest
@testable import Reservoir

/// Covers `BaseSchedule` and `MonthBoundary` (reservoir-j8t): the monthly base and the
/// "Start fresh" reset on top of the existing carry-forward loop. The pre-existing goal
/// behavior is covered, unchanged, by `DailyLimitCalculatorTests`.
final class DailyLimitBudgetModeTests: XCTestCase {

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func input(
        monthly: Decimal,
        boundary: MonthBoundary,
        start: Date,
        spend: [(Date, Decimal)] = []
    ) -> GoalCarryForwardInput {
        GoalCarryForwardInput(
            id: "budget",
            schedule: .monthly(monthly),
            monthBoundary: boundary,
            effectiveStartDate: start,
            spendEntries: spend.map { .init(date: $0.0, amount: $0.1, kind: .variable) }
        )
    }

    private func base(_ monthly: Decimal, _ day: Date) -> Decimal {
        BaseSchedule.monthly(monthly).base(on: day, calendar: calendar)
    }

    // MARK: - Base schedule

    private func monthSum(year: Int, month: Int, monthly: Decimal) -> Decimal {
        let first = date(year, month, 1)
        let days = calendar.range(of: .day, in: .month, for: first)!.count
        return (1...days).reduce(Decimal(0)) { $0 + base(monthly, date(year, month, $1)) }
    }

    func testMonthlyBaseSumsExactlyToMonthlyAmountFor28_29_30_31DayMonths() {
        for monthly in [Decimal(1000), Decimal(1234.56), Decimal(3100), Decimal(1)] {
            XCTAssertEqual(monthSum(year: 2026, month: 2, monthly: monthly), monthly, "28-day Feb")
            XCTAssertEqual(monthSum(year: 2024, month: 2, monthly: monthly), monthly, "29-day leap Feb")
            XCTAssertEqual(monthSum(year: 2026, month: 4, monthly: monthly), monthly, "30-day Apr")
            XCTAssertEqual(monthSum(year: 2026, month: 1, monthly: monthly), monthly, "31-day Jan")
        }
    }

    /// Extremes: a one-cent budget, a zero budget, and amounts far beyond any real budget must
    /// still sum exactly (the last-day remainder absorbs the 10-decimal rounding) with no
    /// day going negative.
    func testMonthlyBaseSumsExactlyAtExtremesAndNeverGoesNegative() {
        for monthly in [Decimal(0), Decimal(string: "0.01")!, Decimal(string: "0.07")!, Decimal(string: "99999999999.99")!, Decimal(string: "1000000000000000")!] {
            for month in [1, 2, 4] {
                XCTAssertEqual(monthSum(year: 2026, month: month, monthly: monthly), monthly, "monthly \(monthly), month \(month)")
            }
            XCTAssertGreaterThanOrEqual(base(monthly, date(2026, 1, 31)), 0, "the remainder day is never negative for \(monthly)")
        }
    }

    func testMonthlyBaseRoundsSharePlainToTenPlaces() {
        // 1000 / 30 = 33.3333333333... -> 33.3333333333 (10 places, plain), last day takes the rest.
        XCTAssertEqual(base(1000, date(2026, 4, 1)), Decimal(string: "33.3333333333")!)
        XCTAssertEqual(base(1000, date(2026, 4, 30)), Decimal(1000) - Decimal(string: "33.3333333333")! * 29)
        // 200 / 30 = 6.666...67 rounds UP at the 10th place (plain, not banker's/truncating).
        XCTAssertEqual(base(200, date(2026, 4, 1)), Decimal(string: "6.6666666667")!)
    }

    func testMonthlyBaseUsesThatDaysMonthLength() {
        XCTAssertEqual(base(3100, date(2026, 1, 10)), 100)          // 31 days
        XCTAssertEqual(base(2800, date(2026, 2, 10)), 100)          // 28 days
        XCTAssertEqual(base(2900, date(2024, 2, 10)), 100)          // 29 days
        XCTAssertEqual(base(3000, date(2026, 4, 10)), 100)          // 30 days
    }

    func testConstantScheduleIgnoresDay() {
        XCTAssertEqual(BaseSchedule.constant(25).base(on: date(2026, 2, 3), calendar: calendar), 25)
        XCTAssertEqual(BaseSchedule.constant(25).base(on: date(2026, 3, 31), calendar: calendar), 25)
    }

    func testConvenienceInitKeepsScalarDailyBaseAndCarryDefaults() {
        let legacy = GoalCarryForwardInput(id: "g", dailyBase: 25, effectiveStartDate: date(2026, 1, 1), spendEntries: [])
        XCTAssertEqual(legacy.dailyBase, 25)
        XCTAssertEqual(legacy.schedule, .constant(25))
        XCTAssertEqual(legacy.monthBoundary, .carry)
    }

    func testDailyLimitReportsBaseOnReferenceDay() {
        let budget = input(monthly: 3100, boundary: .carry, start: date(2026, 1, 1))
        let limit = DailyLimitCalculator.dailyLimit(for: budget, asOf: date(2026, 1, 4), calendar: calendar)
        XCTAssertEqual(limit.dailyBase, 100)
        XCTAssertEqual(limit.carryForward, 300)
        XCTAssertEqual(limit.limit, 400)
    }

    // MARK: - Carry vs reset

    func testCarryModeRollsSurplusAcrossMonthBoundary() {
        // March has 31 days at 100/day; reference April 3.
        let carry = DailyLimitCalculator.carryForward(
            for: input(monthly: 3100, boundary: .carry, start: date(2026, 3, 1)),
            asOf: date(2026, 4, 3), calendar: calendar
        )
        XCTAssertEqual(carry, 3100 + base(3100, date(2026, 4, 1)) + base(3100, date(2026, 4, 2)))
    }

    func testResetModeDropsMarchSurplusButKeepsAprilToDate() {
        let carry = DailyLimitCalculator.carryForward(
            for: input(monthly: 3100, boundary: .reset, start: date(2026, 3, 1)),
            asOf: date(2026, 4, 3), calendar: calendar
        )
        XCTAssertEqual(carry, base(3100, date(2026, 4, 1)) + base(3100, date(2026, 4, 2)))
    }

    func testResetModeDropsDebtOnTheFirst() {
        let spend: [(Date, Decimal)] = [(date(2026, 3, 5), 2000)]
        let reset = DailyLimitCalculator.carryForward(
            for: input(monthly: 3100, boundary: .reset, start: date(2026, 3, 1), spend: spend),
            asOf: date(2026, 4, 2), calendar: calendar
        )
        let carry = DailyLimitCalculator.carryForward(
            for: input(monthly: 3100, boundary: .carry, start: date(2026, 3, 1), spend: spend),
            asOf: date(2026, 4, 2), calendar: calendar
        )
        XCTAssertEqual(reset, base(3100, date(2026, 4, 1)))
        XCTAssertEqual(carry, 3100 - 2000 + base(3100, date(2026, 4, 1)))
    }

    func testResetModeReferenceDateOnTheFirstIsZeroCarry() {
        let carry = DailyLimitCalculator.carryForward(
            for: input(monthly: 3100, boundary: .reset, start: date(2026, 3, 1), spend: [(date(2026, 3, 31), 10)]),
            asOf: date(2026, 4, 1), calendar: calendar
        )
        XCTAssertEqual(carry, 0)
        let limit = DailyLimitCalculator.dailyLimit(
            for: input(monthly: 3100, boundary: .reset, start: date(2026, 3, 1)),
            asOf: date(2026, 4, 1), calendar: calendar
        )
        XCTAssertEqual(limit.limit, limit.dailyBase)
    }

    func testResetModeAppliesEveryMonthAcrossMultipleBoundaries() {
        // Jan -> Mar with a multi-day gap of no spend; only March-to-date survives.
        let carry = DailyLimitCalculator.carryForward(
            for: input(monthly: 3100, boundary: .reset, start: date(2026, 1, 1)),
            asOf: date(2026, 3, 6), calendar: calendar
        )
        let expected = (1...5).reduce(Decimal(0)) { $0 + base(3100, date(2026, 3, $1)) }
        XCTAssertEqual(carry, expected)
    }

    func testStartingOnTheFirstSameResultInBothModes() {
        // Mid-month reference: start 1st, today the 18th.
        let spend: [(Date, Decimal)] = [(date(2026, 1, 3), 250), (date(2026, 1, 10), 40)]
        let carry = DailyLimitCalculator.carryForward(
            for: input(monthly: 3100, boundary: .carry, start: date(2026, 1, 1), spend: spend),
            asOf: date(2026, 1, 18), calendar: calendar
        )
        let reset = DailyLimitCalculator.carryForward(
            for: input(monthly: 3100, boundary: .reset, start: date(2026, 1, 1), spend: spend),
            asOf: date(2026, 1, 18), calendar: calendar
        )
        XCTAssertEqual(carry, 17 * 100 - 290)
        XCTAssertEqual(reset, carry)
    }

    func testStartInPriorMonthMidMonthCarryAccumulatesResetOnlyCurrentMonth() {
        // Start Feb 20 (28-day Feb, 100/day at 2800), reference Mar 10 (31 days).
        let carryMode = DailyLimitCalculator.carryForward(
            for: input(monthly: 2800, boundary: .carry, start: date(2026, 2, 20)),
            asOf: date(2026, 3, 10), calendar: calendar
        )
        let resetMode = DailyLimitCalculator.carryForward(
            for: input(monthly: 2800, boundary: .reset, start: date(2026, 2, 20)),
            asOf: date(2026, 3, 10), calendar: calendar
        )
        let feb = Decimal(9) * 100                        // Feb 20...28
        let marchToDate = (1...9).reduce(Decimal(0)) { $0 + base(2800, date(2026, 3, $1)) }
        XCTAssertEqual(carryMode, feb + marchToDate)
        XCTAssertEqual(resetMode, marchToDate)
    }

    func testFixedEntriesStillExcludedForBudgetSchedules() {
        let budget = GoalCarryForwardInput(
            id: "b", schedule: .monthly(3100), monthBoundary: .carry,
            effectiveStartDate: date(2026, 1, 1),
            spendEntries: [.init(date: date(2026, 1, 2), amount: 500, kind: .fixed)]
        )
        XCTAssertEqual(DailyLimitCalculator.carryForward(for: budget, asOf: date(2026, 1, 4), calendar: calendar), 300)
    }
}
