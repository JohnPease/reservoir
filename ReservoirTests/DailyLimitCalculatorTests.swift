import XCTest
@testable import Reservoir

final class DailyLimitCalculatorTests: XCTestCase {

    /// Fixed calendar/timezone so day-boundary math is deterministic regardless of the
    /// machine running the tests.
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func day(_ offset: Int, from base: Date) -> Date {
        calendar.date(byAdding: .day, value: offset, to: base)!
    }

    private var referenceStart: Date {
        calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!
    }

    // MARK: - dailyBase

    func testDailyBaseComputesTargetMinusStartingOverTotalDays() {
        let start = referenceStart
        let target = day(30, from: start)

        let base = DailyLimitCalculator.dailyBase(
            targetAmount: 1000,
            startingBalance: 100,
            startDate: start,
            targetDate: target,
            calendar: calendar
        )

        XCTAssertEqual(base, 30)
    }

    func testDailyBaseIsZeroWhenTargetDateNotAfterStartDate() {
        let start = referenceStart

        let base = DailyLimitCalculator.dailyBase(
            targetAmount: 1000,
            startingBalance: 100,
            startDate: start,
            targetDate: start,
            calendar: calendar
        )

        XCTAssertEqual(base, 0)
    }

    func testTotalDaysFromStartCountsWholeCalendarDays() {
        let start = referenceStart
        let target = day(30, from: start)

        XCTAssertEqual(
            DailyLimitCalculator.totalDaysFromStart(startDate: start, targetDate: target, calendar: calendar),
            30
        )
    }

    // MARK: - Overspend / underspend

    func testOverspendDayBorrowsFromFutureDays() {
        let start = referenceStart
        let goal = GoalCarryForwardInput(
            id: "goal",
            dailyBase: 10,
            effectiveStartDate: start,
            spendEntries: [
                .init(date: day(0, from: start), amount: 15, kind: .variable)
            ]
        )

        let result = DailyLimitCalculator.dailyLimit(for: goal, asOf: day(1, from: start), calendar: calendar)

        XCTAssertEqual(result.carryForward, -5)
        XCTAssertEqual(result.limit, 5)
    }

    func testUnderspendDayAddsToFutureDays() {
        let start = referenceStart
        let goal = GoalCarryForwardInput(
            id: "goal",
            dailyBase: 10,
            effectiveStartDate: start,
            spendEntries: [
                .init(date: day(0, from: start), amount: 4, kind: .variable)
            ]
        )

        let result = DailyLimitCalculator.dailyLimit(for: goal, asOf: day(1, from: start), calendar: calendar)

        XCTAssertEqual(result.carryForward, 6)
        XCTAssertEqual(result.limit, 16)
    }

    func testCarryForwardCompoundsAcrossMultipleDays() {
        let start = referenceStart
        let goal = GoalCarryForwardInput(
            id: "goal",
            dailyBase: 10,
            effectiveStartDate: start,
            spendEntries: [
                .init(date: day(0, from: start), amount: 15, kind: .variable), // -5
                .init(date: day(1, from: start), amount: 4, kind: .variable)   // +6
            ]
        )

        // asOf day 2: two complete prior days contribute -5 and +6 => net +1
        let result = DailyLimitCalculator.dailyLimit(for: goal, asOf: day(2, from: start), calendar: calendar)

        XCTAssertEqual(result.carryForward, 1)
        XCTAssertEqual(result.limit, 11)
    }

    func testTodaysOwnSpendIsNotSubtractedFromTheLimit() {
        let start = referenceStart
        let goal = GoalCarryForwardInput(
            id: "goal",
            dailyBase: 10,
            effectiveStartDate: start,
            spendEntries: [
                .init(date: day(0, from: start), amount: 9999, kind: .variable)
            ]
        )

        // asOf the same day the spend happened: that day hasn't completed yet, so it
        // must not be included in carry-forward.
        let result = DailyLimitCalculator.dailyLimit(for: goal, asOf: day(0, from: start), calendar: calendar)

        XCTAssertEqual(result.carryForward, 0)
        XCTAssertEqual(result.limit, 10)
    }

    // MARK: - Multi-day gaps

    func testMultiDayGapCarriesForwardEveryUntouchedDay() {
        let start = referenceStart
        let goal = GoalCarryForwardInput(
            id: "goal",
            dailyBase: 10,
            effectiveStartDate: start,
            spendEntries: [] // app not opened; no transactions recorded at all
        )

        // 5 complete days with zero spend each: carry = 5 * 10 = 50
        let result = DailyLimitCalculator.dailyLimit(for: goal, asOf: day(5, from: start), calendar: calendar)

        XCTAssertEqual(result.carryForward, 50)
        XCTAssertEqual(result.limit, 60)
    }

    func testMultiDayGapWithPartialSpendOnOneDay() {
        let start = referenceStart
        let goal = GoalCarryForwardInput(
            id: "goal",
            dailyBase: 10,
            effectiveStartDate: start,
            spendEntries: [
                .init(date: day(2, from: start), amount: 25, kind: .variable) // day 2 only, overspend by 15
            ]
        )

        // Days 0,1,3,4 fully underspent (+10 each = 40), day 2 overspent (-15) => 25
        let result = DailyLimitCalculator.dailyLimit(for: goal, asOf: day(5, from: start), calendar: calendar)

        XCTAssertEqual(result.carryForward, 25)
        XCTAssertEqual(result.limit, 35)
    }

    // MARK: - Goal edited mid-stream

    func testGoalEditResetsCarryForwardFromTheEditDate() {
        let start = referenceStart
        // Old spend history before the edit (day 0-4) should have no bearing once the
        // goal is edited: the effective start date moves to the edit date, and the base
        // changes to the newly-computed value.
        let goal = GoalCarryForwardInput(
            id: "goal",
            dailyBase: 20, // recomputed at edit time
            effectiveStartDate: day(5, from: start), // edited on day 5
            spendEntries: [
                .init(date: day(0, from: start), amount: 999, kind: .variable), // pre-edit, ignored
                .init(date: day(5, from: start), amount: 15, kind: .variable)   // post-edit, counted (20 - 15 = +5)
            ]
        )

        let result = DailyLimitCalculator.dailyLimit(for: goal, asOf: day(6, from: start), calendar: calendar)

        XCTAssertEqual(result.carryForward, 5)
        XCTAssertEqual(result.limit, 25)
    }

    // MARK: - Fixed vs. variable transactions

    func testFixedTransactionsAreExcludedFromCarryForward() {
        let start = referenceStart
        let goal = GoalCarryForwardInput(
            id: "goal",
            dailyBase: 10,
            effectiveStartDate: start,
            spendEntries: [
                .init(date: day(0, from: start), amount: 3, kind: .variable),
                .init(date: day(0, from: start), amount: 1000, kind: .fixed) // e.g. rent; must not affect the math
            ]
        )

        let result = DailyLimitCalculator.dailyLimit(for: goal, asOf: day(1, from: start), calendar: calendar)

        // Only the $3 variable spend counts: carry = 10 - 3 = 7
        XCTAssertEqual(result.carryForward, 7)
        XCTAssertEqual(result.limit, 17)
    }

    func testDayWithOnlyFixedSpendBanksTheFullBase() {
        let start = referenceStart
        let goal = GoalCarryForwardInput(
            id: "goal",
            dailyBase: 10,
            effectiveStartDate: start,
            spendEntries: [
                .init(date: day(0, from: start), amount: 500, kind: .fixed)
            ]
        )

        let result = DailyLimitCalculator.dailyLimit(for: goal, asOf: day(1, from: start), calendar: calendar)

        XCTAssertEqual(result.carryForward, 10)
        XCTAssertEqual(result.limit, 20)
    }

    // MARK: - Multiple concurrent goals

    func testMultipleGoalsAreComputedIndependentlyNotPooled() {
        let start = referenceStart
        let overspentGoal = GoalCarryForwardInput(
            id: "rainy-day",
            dailyBase: 10,
            effectiveStartDate: start,
            spendEntries: [.init(date: day(0, from: start), amount: 20, kind: .variable)] // -10
        )
        let underspentGoal = GoalCarryForwardInput(
            id: "vacation",
            dailyBase: 20,
            effectiveStartDate: start,
            spendEntries: [.init(date: day(0, from: start), amount: 5, kind: .variable)] // +15
        )

        let asOf = day(1, from: start)
        let individualResults = [overspentGoal, underspentGoal].map {
            DailyLimitCalculator.dailyLimit(for: $0, asOf: asOf, calendar: calendar)
        }

        XCTAssertEqual(individualResults[0].limit, 0)  // 10 + (-10)
        XCTAssertEqual(individualResults[1].limit, 35) // 20 + 15

        let total = DailyLimitCalculator.totalDailyLimit(for: [overspentGoal, underspentGoal], asOf: asOf, calendar: calendar)

        // Sum of independent limits, not a pooled/blended calculation.
        XCTAssertEqual(total, 35)
        XCTAssertEqual(total, individualResults[0].limit + individualResults[1].limit)
    }

    func testTotalDailyLimitWithNoActiveGoalsIsZero() {
        let total = DailyLimitCalculator.totalDailyLimit(for: [], asOf: referenceStart, calendar: calendar)
        XCTAssertEqual(total, 0)
    }
}
