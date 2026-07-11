import XCTest
import SwiftData
@testable import Reservoir

/// Uses a real in-memory `ModelContainer`/`ModelContext`, matching
/// `TodayScreenCalculatorTests`'s pattern — SwiftData's inverse-relationship sync
/// (`goal.transactions`) is only reliable once objects are inserted into a context.
final class GoalsScreenCalculatorTests: XCTestCase {

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        let schema = Schema(versionedSchema: SchemaV3.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, migrationPlan: ReservoirMigrationPlan.self, configurations: [configuration])
        context = ModelContext(container)
    }

    override func tearDownWithError() throws {
        context = nil
        container = nil
    }

    private var today: Date {
        calendar.date(from: DateComponents(year: 2026, month: 1, day: 15))!
    }

    private func day(_ offset: Int, from base: Date? = nil) -> Date {
        calendar.date(byAdding: .day, value: offset, to: base ?? today)!
    }

    @discardableResult
    private func makeGoal(
        targetAmount: Decimal = 1000,
        startDate: Date? = nil,
        targetDate: Date? = nil,
        startingBalance: Decimal = 0,
        dailyBase: Decimal = 10,
        lastEditedDate: Date? = nil,
        createdAt: Date? = nil
    ) -> SavingsGoal {
        let resolvedStartDate = startDate ?? day(-10)
        let goal = SavingsGoal(
            targetAmount: targetAmount,
            targetDate: targetDate ?? day(10),
            startDate: resolvedStartDate,
            startingBalance: startingBalance,
            dailyBase: dailyBase,
            lastEditedDate: lastEditedDate,
            dismissedAt: nil,
            createdAt: createdAt ?? resolvedStartDate
        )
        context.insert(goal)
        return goal
    }

    @discardableResult
    private func makeTransaction(
        amount: Decimal,
        date: Date,
        type: TransactionType = .variable,
        savingsGoal: SavingsGoal? = nil
    ) -> SpendTransaction {
        let transaction = SpendTransaction(
            amount: amount,
            date: date,
            merchantName: "Merchant",
            type: type,
            entryMethod: .manual,
            savingsGoal: savingsGoal
        )
        context.insert(transaction)
        return transaction
    }

    // MARK: - currentBalance / progress (reservoir-1et: banked-surplus carry-forward)

    func testCurrentBalanceIsStartingBalancePlusCarryForward() throws {
        // dailyBase 10, 5 elapsed days (day(-5)..<today) with no spend => carryForward
        // == 5 * 10 == 50. currentBalance == startingBalance + carryForward == 150.
        let goal = makeGoal(startDate: day(-5), startingBalance: 100, dailyBase: 10, createdAt: day(-5))
        try context.save()

        XCTAssertEqual(GoalsScreenCalculator.currentBalance(for: goal, referenceDate: today, calendar: calendar), 150)
    }

    func testCurrentBalanceReachesTargetAmountAtTargetDateWithZeroSpendThroughout() throws {
        // The exact confirmed walkthrough: spending $0/day for the goal's full duration
        // banks the full dailyBase every day, so as of targetDate, currentBalance ==
        // targetAmount exactly (100%). `carryForward` excludes its `asOf` day's own spend
        // (same convention the Today screen's "remaining today" uses), so referenceDate
        // == targetDate itself sums exactly `totalDaysFromStart` (20) days — matching the
        // same divisor `dailyBase` was computed from, landing exactly on `targetAmount`
        // with no off-by-one.
        let targetDate = day(10)
        let goal = makeGoal(targetAmount: 1000, startDate: day(-10), targetDate: targetDate, startingBalance: 0, dailyBase: 50, createdAt: day(-10))
        try context.save()

        XCTAssertEqual(GoalsScreenCalculator.currentBalance(for: goal, referenceDate: targetDate, calendar: calendar), 1000)
        XCTAssertEqual(GoalsScreenCalculator.progressPercentRounded(for: goal, referenceDate: targetDate, calendar: calendar), 100)
    }

    func testCurrentBalanceUnchangedWhenSpendingExactlyTodaysDisplayedDailyLimit() throws {
        // Goal starts exactly today (effectiveStartDate == today), so carryForward as of
        // today is 0 and today's displayed daily limit is exactly dailyBase. Spending
        // exactly that limit nets ZERO progress change: currentBalance as of tomorrow
        // (after today's exact-limit spend) equals currentBalance as of today (before it)
        // — both sit at startingBalance, confirming a day of exact-limit spending is
        // truly neutral, not a gain or a loss.
        let goal = makeGoal(startDate: today, startingBalance: 100, dailyBase: 10, createdAt: today)
        try context.save()

        let balanceBeforeTodaysSpend = GoalsScreenCalculator.currentBalance(for: goal, referenceDate: today, calendar: calendar)

        let input = TodayScreenCalculator.carryForwardInput(for: goal, calendar: calendar)
        let todaysLimit = DailyLimitCalculator.dailyLimit(for: input, asOf: today, calendar: calendar).limit
        XCTAssertEqual(todaysLimit, 10) // dailyBase + 0 carryForward, confirming the setup.
        makeTransaction(amount: todaysLimit, date: today, type: .variable, savingsGoal: goal)
        try context.save()

        let balanceAfterTodaysSpend = GoalsScreenCalculator.currentBalance(for: goal, referenceDate: day(1), calendar: calendar)
        XCTAssertEqual(balanceAfterTodaysSpend, balanceBeforeTodaysSpend)
        XCTAssertEqual(balanceAfterTodaysSpend, goal.startingBalance)
    }

    func testCurrentBalanceErodesBelowStartingBalanceWhenOverspending() throws {
        // Overspending drives carryForward negative, so currentBalance can drop below
        // startingBalance — the opposite of the old (buggy) "more spending == more
        // progress" formula.
        let goal = makeGoal(startDate: day(-1), startingBalance: 100, dailyBase: 10, createdAt: day(-1))
        makeTransaction(amount: 500, date: day(-1), type: .variable, savingsGoal: goal)
        try context.save()

        // 1 elapsed day: carryForward == 10 - 500 == -490.
        XCTAssertEqual(GoalsScreenCalculator.currentBalance(for: goal, referenceDate: today, calendar: calendar), -390)
        XCTAssertLessThan(GoalsScreenCalculator.currentBalance(for: goal, referenceDate: today, calendar: calendar), goal.startingBalance)
    }

    func testCurrentBalanceUnaffectedByFixedTransactions() throws {
        // A fixed-kind transaction attributed to the goal does NOT erode progress,
        // consistent with DailyLimitCalculator.carryForward's existing exclusion of
        // fixed-kind entries from its per-day sum.
        let goal = makeGoal(startDate: day(-5), startingBalance: 100, dailyBase: 10, createdAt: day(-5))
        makeTransaction(amount: 500, date: day(-2), type: .fixed, savingsGoal: goal)
        try context.save()

        // No variable spend => carryForward == 5 * 10 == 50, unaffected by the $500 fixed
        // transaction.
        XCTAssertEqual(GoalsScreenCalculator.currentBalance(for: goal, referenceDate: today, calendar: calendar), 150)
    }

    func testProgressFractionComputesRatioOfCurrentGainToTargetGain() throws {
        // dailyBase == (1000-0)/20 == 50; 5 elapsed days with no spend => carryForward ==
        // 250 => currentBalance == 250 => progressFraction == 250/1000 == 0.25.
        let goal = makeGoal(targetAmount: 1000, startDate: day(-5), targetDate: day(15), startingBalance: 0, dailyBase: 50, createdAt: day(-5))
        try context.save()

        XCTAssertEqual(GoalsScreenCalculator.progressFraction(for: goal, referenceDate: today, calendar: calendar), 0.25)
    }

    func testProgressFractionCanExceedOneHundredPercent() throws {
        // dailyBase == 100/2 == 50; 3 elapsed days with no spend => carryForward == 150
        // => progressFraction == 150/100 == 1.5.
        let goal = makeGoal(targetAmount: 100, startDate: day(-3), targetDate: day(2), startingBalance: 0, dailyBase: 50, createdAt: day(-3))
        try context.save()

        XCTAssertEqual(GoalsScreenCalculator.progressFraction(for: goal, referenceDate: today, calendar: calendar), 1.5)
    }

    func testProgressFractionCanBeNegative() throws {
        // Overspending on an elapsed day drives carryForward, and therefore
        // progressFraction, negative.
        let goal = makeGoal(targetAmount: 1000, startDate: day(-1), startingBalance: 100, dailyBase: 10, createdAt: day(-1))
        makeTransaction(amount: 100, date: day(-1), type: .variable, savingsGoal: goal)
        try context.save()

        XCTAssertLessThan(GoalsScreenCalculator.progressFraction(for: goal, referenceDate: today, calendar: calendar), 0)
    }

    func testClampedProgressFractionClampsAboveOneToOne() throws {
        let goal = makeGoal(targetAmount: 100, startDate: day(-30), targetDate: day(-10), startingBalance: 0, dailyBase: 10, createdAt: day(-30))
        try context.save()

        XCTAssertEqual(GoalsScreenCalculator.clampedProgressFraction(for: goal, referenceDate: today, calendar: calendar), 1)
    }

    func testClampedProgressFractionClampsBelowZeroToZero() throws {
        // denominator <= 0 guard: targetAmount == startingBalance shouldn't be reachable
        // via validated UI, but the calculator must not divide by zero if it occurs.
        let goal = makeGoal(targetAmount: 100, startingBalance: 100)
        XCTAssertEqual(GoalsScreenCalculator.clampedProgressFraction(for: goal, referenceDate: today, calendar: calendar), 0)
    }

    // MARK: - progressPercentRounded (code-review: nearest-rounding, not truncation)

    func testProgressPercentRoundedRoundsFractionalPercentUpToNearestWholeNumber() throws {
        // dailyBase == 1000/1000 == 1; 669 elapsed days with no spend => carryForward ==
        // 669 => 66.9% — must round to the *nearest* whole percent (67), not truncate
        // toward zero (66), which `NSDecimalNumber.intValue` alone would do.
        let goal = makeGoal(targetAmount: 1000, startDate: day(-669), targetDate: day(331), startingBalance: 0, dailyBase: 1, createdAt: day(-669))
        try context.save()

        XCTAssertEqual(GoalsScreenCalculator.progressPercentRounded(for: goal, referenceDate: today, calendar: calendar), 67)
    }

    func testProgressPercentRoundedRoundsFractionalPercentDownToNearestWholeNumber() throws {
        // 661 elapsed days with no spend, dailyBase 1 => carryForward == 661 => 66.1% —
        // must round down to 66, not up to 67, confirming this is true nearest-rounding
        // and not always-round-up.
        let goal = makeGoal(targetAmount: 1000, startDate: day(-661), targetDate: day(339), startingBalance: 0, dailyBase: 1, createdAt: day(-661))
        try context.save()

        XCTAssertEqual(GoalsScreenCalculator.progressPercentRounded(for: goal, referenceDate: today, calendar: calendar), 66)
    }

    func testProgressPercentRoundedHandlesExactWholeNumberPercent() throws {
        let goal = makeGoal(targetAmount: 1000, startDate: day(-250), targetDate: day(750), startingBalance: 0, dailyBase: 1, createdAt: day(-250))
        try context.save()

        XCTAssertEqual(GoalsScreenCalculator.progressPercentRounded(for: goal, referenceDate: today, calendar: calendar), 25)
    }

    // MARK: - Pace segment

    func testPaceStatusUnavailableWhenDailyBaseIsZero() {
        let goal = makeGoal(dailyBase: 0)
        XCTAssertEqual(
            GoalsScreenCalculator.paceStatus(for: goal, referenceDate: today, calendar: calendar),
            .unavailable
        )
    }

    func testPaceStatusOnPaceWhenCarryForwardIsNonNegative() {
        // No spend recorded — every elapsed day contributes a full dailyBase, so
        // carryForward is comfortably >= 0.
        let goal = makeGoal(startDate: day(-5), dailyBase: 10)
        XCTAssertEqual(
            GoalsScreenCalculator.paceStatus(for: goal, referenceDate: today, calendar: calendar),
            .onPace(targetDate: goal.targetDate)
        )
    }

    func testPaceStatusBehindPaceComputesDaysBehindFormula() throws {
        // dailyBase 10, 5 elapsed days (day(-5)..<today) => carryForward would be +50
        // with no spend. A single 100 overspend on day(-5) makes carryForward = 50 - 100
        // = -50. N = ceil(abs(-50)/10) = 5.
        let goal = makeGoal(startDate: day(-5), dailyBase: 10)
        makeTransaction(amount: 100, date: day(-5), type: .variable, savingsGoal: goal)
        try context.save()

        XCTAssertEqual(
            GoalsScreenCalculator.paceStatus(for: goal, referenceDate: today, calendar: calendar),
            .behindPace(daysBehind: 5)
        )
    }

    func testPaceStatusBehindPaceRoundsUpFractionalDaysBehind() throws {
        // dailyBase 10, 2 elapsed days => carryForward without spend = +20. A single 35
        // overspend => carryForward = 20 - 35 = -15. N = ceil(15/10) = 2.
        let goal = makeGoal(startDate: day(-2), dailyBase: 10)
        makeTransaction(amount: 35, date: day(-2), type: .variable, savingsGoal: goal)
        try context.save()

        XCTAssertEqual(
            GoalsScreenCalculator.paceStatus(for: goal, referenceDate: today, calendar: calendar),
            .behindPace(daysBehind: 2)
        )
    }

    // MARK: - Simulation segment

    func testSimulationStatusUnavailableWhenDailyBaseIsZero() {
        let goal = makeGoal(dailyBase: 0)
        XCTAssertEqual(
            GoalsScreenCalculator.simulationStatus(for: goal, referenceDate: today, calendar: calendar),
            .unavailable
        )
    }

    func testSimulationStatusNotEnoughHistoryWhenGoalCreatedToday() {
        // effectiveStartDate == today (createdAt == today, startDate == today) => zero
        // elapsed days => windowLength == 0.
        let goal = makeGoal(startDate: today, dailyBase: 10, createdAt: today)
        XCTAssertEqual(
            GoalsScreenCalculator.simulationStatus(for: goal, referenceDate: today, calendar: calendar),
            .notEnoughHistory
        )
    }

    func testSimulationStatusTruncatesWindowForGoalYoungerThanFourteenDays() throws {
        // Goal is only 5 days old — window should be 5, not 14, and avgDailyNet should
        // only reflect those 5 days even if older (out-of-window) spend exists.
        let goal = makeGoal(startDate: day(-5), dailyBase: 10, createdAt: day(-5))
        // Inside the 5-day window: no spend at all => avgDailyNet == dailyBase == 10.
        try context.save()

        guard case .computed(let projection) = GoalsScreenCalculator.simulationStatus(
            for: goal, referenceDate: today, calendar: calendar
        ) else {
            return XCTFail("Expected .computed")
        }
        XCTAssertEqual(projection.avgDailyNet, 10)
    }

    func testSimulationStatusWindowCapsAtFourteenDaysForOlderGoals() throws {
        // Goal is 30 days old; the trailing 14-day window should exclude a large
        // overspend that happened 20 days ago (outside the window), leaving
        // avgDailyNet == dailyBase (no spend in-window).
        let goal = makeGoal(startDate: day(-30), dailyBase: 10, createdAt: day(-30))
        makeTransaction(amount: 10_000, date: day(-20), type: .variable, savingsGoal: goal)
        try context.save()

        guard case .computed(let projection) = GoalsScreenCalculator.simulationStatus(
            for: goal, referenceDate: today, calendar: calendar
        ) else {
            return XCTFail("Expected .computed")
        }
        XCTAssertEqual(projection.avgDailyNet, 10)
    }

    func testSimulationStatusAvgDailyNetNegativeWhenWindowOverspent() throws {
        // 5-day-old goal, dailyBase 10; a 100 overspend on the goal's first elapsed day
        // (day(-5)) drags the 5-day average net negative:
        // (10-100) + 10 + 10 + 10 + 10 = -50, /5 = -10.
        let goal = makeGoal(startDate: day(-5), dailyBase: 10, createdAt: day(-5))
        makeTransaction(amount: 100, date: day(-5), type: .variable, savingsGoal: goal)
        try context.save()

        guard case .computed(let projection) = GoalsScreenCalculator.simulationStatus(
            for: goal, referenceDate: today, calendar: calendar
        ) else {
            return XCTFail("Expected .computed")
        }
        XCTAssertEqual(projection.avgDailyNet, -10)
        XCTAssertLessThan(projection.avgDailyNet, 0)
    }

    func testSimulationProjectedSurplusShortfallAndLateCompletionDateWhenBehind() throws {
        let targetDate = day(5)
        let goal = makeGoal(targetAmount: 1000, startDate: day(-5), targetDate: targetDate, dailyBase: 10, createdAt: day(-5))
        // avgDailyNet == -10 (see above formula), daysRemaining = 5 (today -> targetDate).
        makeTransaction(amount: 100, date: day(-5), type: .variable, savingsGoal: goal)
        try context.save()

        guard case .computed(let projection) = GoalsScreenCalculator.simulationStatus(
            for: goal, referenceDate: today, calendar: calendar
        ) else {
            return XCTFail("Expected .computed")
        }
        XCTAssertEqual(projection.daysRemaining, 5)
        // projectedSurplusShortfall = avgDailyNet * daysRemaining = -10 * 5 = -50.
        XCTAssertEqual(projection.projectedSurplusShortfall, -50)

        // late days = ceil(abs(-50)/10) = 5; completion date = targetDate + 5 days.
        guard case .late(let days, let date) = projection.completionOutcome else {
            return XCTFail("Expected .late outcome")
        }
        XCTAssertEqual(days, 5)
        XCTAssertEqual(date, day(5, from: targetDate))
    }

    func testSimulationProjectedSurplusAndEarlyCompletionDateWhenAhead() throws {
        let targetDate = day(10)
        // 10-day-old goal, dailyBase 10, no spend at all in the trailing window =>
        // avgDailyNet == +10. daysRemaining = 10.
        let goal = makeGoal(targetAmount: 1000, startDate: day(-10), targetDate: targetDate, dailyBase: 10, createdAt: day(-10))
        try context.save()

        guard case .computed(let projection) = GoalsScreenCalculator.simulationStatus(
            for: goal, referenceDate: today, calendar: calendar
        ) else {
            return XCTFail("Expected .computed")
        }
        // projectedSurplusShortfall = 10 * 10 = 100.
        XCTAssertEqual(projection.projectedSurplusShortfall, 100)

        // early days-raw = floor(100/10) = 10; naive completion date = targetDate - 10
        // days == today, which is earlier than "tomorrow" (today+1), so it's floored to
        // tomorrow, and the displayed "early days" recomputed from that floor.
        guard case .early(let days, let date) = projection.completionOutcome else {
            return XCTFail("Expected .early outcome")
        }
        let tomorrow = day(1)
        XCTAssertEqual(date, tomorrow)
        XCTAssertEqual(days, calendar.dateComponents([.day], from: tomorrow, to: targetDate).day)
    }

    func testSimulationOnScheduleNotEarlyWhenTargetDateIsTodayAndAheadOfPace() throws {
        // Regression for the bug where daysRemaining == 0 (targetDate == today) with
        // avgDailyNet > 0 produced a completion date one day *after* targetDate: with no
        // remaining runway, projectedSurplusShortfall is always 0 regardless of
        // avgDailyNet's sign, so earlyDaysRaw floored to 0, leaving the naive completion
        // date at targetDate itself (today) — which then got floored *up* to tomorrow by
        // the "no earlier than tomorrow" guard, landing after targetDate. There's no
        // meaningful "early" with zero days of runway, so this should read as on-schedule
        // at targetDate, not early-but-later-than-target.
        let targetDate = today
        let goal = makeGoal(targetAmount: 1000, startDate: day(-10), targetDate: targetDate, dailyBase: 10, createdAt: day(-10))
        try context.save()

        guard case .computed(let projection) = GoalsScreenCalculator.simulationStatus(
            for: goal, referenceDate: today, calendar: calendar
        ) else {
            return XCTFail("Expected .computed")
        }
        XCTAssertGreaterThan(projection.avgDailyNet, 0)
        XCTAssertEqual(projection.daysRemaining, 0)

        guard case .onSchedule(let date) = projection.completionOutcome else {
            return XCTFail("Expected .onSchedule outcome, got \(projection.completionOutcome)")
        }
        XCTAssertLessThanOrEqual(date, targetDate)
        XCTAssertEqual(date, targetDate)
    }

    func testSimulationLateCompletionWhenTargetDateIsTodayAndBehindPace() throws {
        // Companion to the on-schedule/ahead-of-pace regression above: a goal due today
        // that's already behind pace. daysRemaining == 0 makes
        // projectedSurplusShortfall == avgDailyNet * 0 == 0 regardless of avgDailyNet's
        // magnitude, so lateDays == ceil(abs(0)/dailyBase) == 0 and completionDate ==
        // targetDate + 0 days == targetDate itself — "0 days late, due today" is a sane,
        // non-contradictory read (unlike the ahead-of-pace case, this branch was never
        // floored past targetDate, so it needed no code change — this test just locks
        // down that the untouched .late branch stays correct at this edge).
        let targetDate = today
        let goal = makeGoal(targetAmount: 1000, startDate: day(-10), targetDate: targetDate, dailyBase: 10, createdAt: day(-10))
        // 9 days of no spend (+10 each = 90) plus one $200 day (10 - 200 = -190) over the
        // 10-day window nets to (90 - 190) / 10 == -10 average daily net.
        makeTransaction(amount: 200, date: day(-5), type: .variable, savingsGoal: goal)
        try context.save()

        guard case .computed(let projection) = GoalsScreenCalculator.simulationStatus(
            for: goal, referenceDate: today, calendar: calendar
        ) else {
            return XCTFail("Expected .computed")
        }
        XCTAssertLessThan(projection.avgDailyNet, 0)
        XCTAssertEqual(projection.daysRemaining, 0)

        guard case .late(let days, let date) = projection.completionOutcome else {
            return XCTFail("Expected .late outcome, got \(projection.completionOutcome)")
        }
        XCTAssertEqual(days, 0)
        XCTAssertEqual(date, targetDate)
    }

    func testSimulationOnScheduleWhenAvgDailyNetIsExactlyZero() throws {
        let targetDate = day(10)
        let goal = makeGoal(targetAmount: 1000, startDate: day(-10), targetDate: targetDate, dailyBase: 10, createdAt: day(-10))
        // Exactly consume the full dailyBase every day in-window => avgDailyNet == 0.
        for offset in -10..<0 {
            makeTransaction(amount: 10, date: day(offset), type: .variable, savingsGoal: goal)
        }
        try context.save()

        guard case .computed(let projection) = GoalsScreenCalculator.simulationStatus(
            for: goal, referenceDate: today, calendar: calendar
        ) else {
            return XCTFail("Expected .computed")
        }
        XCTAssertEqual(projection.avgDailyNet, 0)
        guard case .onSchedule(let date) = projection.completionOutcome else {
            return XCTFail("Expected .onSchedule outcome")
        }
        XCTAssertEqual(date, targetDate)
    }

    func testSimulationExcludesFixedSpendFromWindowAverage() throws {
        // Fixed-kind spend is excluded from the daily-net calculation, same rule
        // DailyLimitCalculator.carryForward already applies — a large fixed transaction
        // shouldn't drag avgDailyNet down.
        let goal = makeGoal(startDate: day(-5), dailyBase: 10, createdAt: day(-5))
        makeTransaction(amount: 500, date: day(-3), type: .fixed, savingsGoal: goal)
        try context.save()

        guard case .computed(let projection) = GoalsScreenCalculator.simulationStatus(
            for: goal, referenceDate: today, calendar: calendar
        ) else {
            return XCTFail("Expected .computed")
        }
        XCTAssertEqual(projection.avgDailyNet, 10)
    }
}
