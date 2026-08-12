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
        let schema = Schema(versionedSchema: SchemaV7.self)
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

    // MARK: - Spend chart window (reservoir-t5u)

    private func makeInput(
        effectiveStartDate: Date,
        dailyBase: Decimal = 10,
        spendEntries: [GoalCarryForwardInput.SpendEntry] = []
    ) -> GoalCarryForwardInput {
        GoalCarryForwardInput(
            id: AnyHashable("chart-test-goal"),
            dailyBase: dailyBase,
            effectiveStartDate: effectiveStartDate,
            spendEntries: spendEntries
        )
    }

    // MARK: <3-day "not enough data" cutoff (window-length math at 2/3/4 days)

    func testChartWindowLengthIsTwoWithExactlyTwoDaysOfHistory() {
        // effectiveStartDate == day(-1): day(-1) and today, inclusive, is 2 days.
        let input = makeInput(effectiveStartDate: day(-1))
        XCTAssertEqual(GoalsScreenCalculator.chartWindowLength(effectiveStartDate: input.effectiveStartDate, windowEnd: today, calendar: calendar), 2)

        let points = GoalsScreenCalculator.spendChartWindow(input: input, windowEnd: today, calendar: calendar)
        XCTAssertEqual(points.count, 2)
        // Below GoalSpendingChartView's minimumPointCount of 3 — the view renders the
        // "not enough data" state at this count, but the calculator itself still
        // produces a correct (if short) window; that threshold is a view-layer concern.
        XCTAssertLessThan(points.count, 3)
    }

    func testChartWindowLengthIsThreeWithExactlyThreeDaysOfHistory() {
        // effectiveStartDate == day(-2): day(-2), day(-1), today == 3 days, exactly at
        // the "not enough data" cutoff — this is the first count the view treats as
        // chartable.
        let input = makeInput(effectiveStartDate: day(-2))
        XCTAssertEqual(GoalsScreenCalculator.chartWindowLength(effectiveStartDate: input.effectiveStartDate, windowEnd: today, calendar: calendar), 3)

        let points = GoalsScreenCalculator.spendChartWindow(input: input, windowEnd: today, calendar: calendar)
        XCTAssertEqual(points.count, 3)
        XCTAssertEqual(points.first?.day, calendar.startOfDay(for: day(-2)))
        XCTAssertEqual(points.last?.day, calendar.startOfDay(for: today))
    }

    func testChartWindowLengthIsFourWithExactlyFourDaysOfHistory() {
        let input = makeInput(effectiveStartDate: day(-3))
        XCTAssertEqual(GoalsScreenCalculator.chartWindowLength(effectiveStartDate: input.effectiveStartDate, windowEnd: today, calendar: calendar), 4)

        let points = GoalsScreenCalculator.spendChartWindow(input: input, windowEnd: today, calendar: calendar)
        XCTAssertEqual(points.count, 4)
    }

    // MARK: Goal-creation-date boundary (earliest page stops exactly at effectiveStartDate)

    func testChartWindowLengthCapsAtThirtyDaysForOlderGoals() {
        // effectiveStartDate 40 days before windowEnd => 41 days of raw history, capped
        // to 30.
        let input = makeInput(effectiveStartDate: day(-40))
        XCTAssertEqual(GoalsScreenCalculator.chartWindowLength(effectiveStartDate: input.effectiveStartDate, windowEnd: today, calendar: calendar), 30)

        let points = GoalsScreenCalculator.spendChartWindow(input: input, windowEnd: today, calendar: calendar)
        XCTAssertEqual(points.count, 30)
        // The window's start is 29 days before windowEnd (30 days inclusive), NOT the
        // goal's actual effectiveStartDate — confirms the 30-day cap, not the
        // goal-start boundary, is what's biting here.
        XCTAssertEqual(points.first?.day, calendar.startOfDay(for: day(-29)))
        XCTAssertEqual(points.last?.day, calendar.startOfDay(for: today))
    }

    func testChartWindowCountAndEarliestPageBoundAtGoalCreationDateWithNoOffByOne() {
        // 66 days of total history (effectiveStartDate through today, inclusive):
        // page 0 and page 1 are full 30-day windows: totalDays - 30*2 = 6 days left over
        // for the earliest page => chartWindowCount == ceil(66/30) == 3.
        let effectiveStartDate = day(-65)
        let input = makeInput(effectiveStartDate: effectiveStartDate)

        let windowCount = GoalsScreenCalculator.chartWindowCount(effectiveStartDate: effectiveStartDate, referenceDate: today, calendar: calendar)
        XCTAssertEqual(windowCount, 3)

        // Page 0 (most recent): windowEnd == today, full 30-day window.
        let page0End = GoalsScreenCalculator.chartWindowEnd(page: 0, referenceDate: today, calendar: calendar)
        XCTAssertEqual(page0End, calendar.startOfDay(for: today))
        let page0Points = GoalsScreenCalculator.spendChartWindow(input: input, windowEnd: page0End, calendar: calendar)
        XCTAssertEqual(page0Points.count, 30)

        // Page 1 (middle): windowEnd == today - 30, another full 30-day window.
        let page1End = GoalsScreenCalculator.chartWindowEnd(page: 1, referenceDate: today, calendar: calendar)
        XCTAssertEqual(page1End, calendar.startOfDay(for: day(-30)))
        let page1Points = GoalsScreenCalculator.spendChartWindow(input: input, windowEnd: page1End, calendar: calendar)
        XCTAssertEqual(page1Points.count, 30)

        // Page 2 (earliest / last page, index windowCount - 1): windowEnd == today - 60.
        // Its window must stop EXACTLY at effectiveStartDate — no day before it, and no
        // gap day skipped (off-by-one in either direction).
        let page2End = GoalsScreenCalculator.chartWindowEnd(page: windowCount - 1, referenceDate: today, calendar: calendar)
        XCTAssertEqual(page2End, calendar.startOfDay(for: day(-60)))
        let page2Points = GoalsScreenCalculator.spendChartWindow(input: input, windowEnd: page2End, calendar: calendar)
        // 6 days: effectiveStartDate (day(-65)) through page2End (day(-60)) inclusive.
        XCTAssertEqual(page2Points.count, 6)
        XCTAssertEqual(page2Points.first?.day, calendar.startOfDay(for: effectiveStartDate), "Earliest page must start exactly at the goal's effectiveStartDate, not before or after it")
        XCTAssertEqual(page2Points.last?.day, page2End)
    }

    func testChartWindowCountIsOneForGoalCreatedToday() {
        // effectiveStartDate == referenceDate: a single (short, 1-day) page, never zero.
        XCTAssertEqual(GoalsScreenCalculator.chartWindowCount(effectiveStartDate: today, referenceDate: today, calendar: calendar), 1)
    }

    func testChartWindowLengthIsZeroWhenWindowEndPrecedesEffectiveStartDate() {
        // Defensive: a windowEnd earlier than the goal's own start shouldn't be reachable
        // via chartWindowEnd's own page bounding, but the function itself must not
        // produce a negative-length or garbage window if it is ever called that way.
        XCTAssertEqual(GoalsScreenCalculator.chartWindowLength(effectiveStartDate: today, windowEnd: day(-1), calendar: calendar), 0)
        XCTAssertEqual(GoalsScreenCalculator.spendChartWindow(input: makeInput(effectiveStartDate: today), windowEnd: day(-1), calendar: calendar), [])
    }

    // MARK: Non-"today" windowEnd (paged-back modal view)

    func testSpendChartWindowWithPastWindowEndReflectsThatWindowNotRealToday() {
        // A goal with 50 days of history; page back to a windowEnd 40 days before
        // "today" and confirm the returned points are anchored to THAT windowEnd, not
        // to `today` — this is the crux of paging correctness: the function must never
        // implicitly reach for "now."
        let effectiveStartDate = day(-50)
        let pastWindowEnd = day(-40)
        let spendDay = day(-45)
        let input = makeInput(
            effectiveStartDate: effectiveStartDate,
            dailyBase: 10,
            spendEntries: [GoalCarryForwardInput.SpendEntry(date: spendDay, amount: 25, kind: .variable)]
        )

        let points = GoalsScreenCalculator.spendChartWindow(input: input, windowEnd: pastWindowEnd, calendar: calendar)

        // 11 days: effectiveStartDate (day(-50)) through pastWindowEnd (day(-40))
        // inclusive.
        XCTAssertEqual(points.count, 11)
        XCTAssertEqual(points.last?.day, calendar.startOfDay(for: pastWindowEnd), "Window must end at the passed-in windowEnd, not at today")
        XCTAssertEqual(points.first?.day, calendar.startOfDay(for: effectiveStartDate))

        guard let spendPoint = points.first(where: { $0.day == calendar.startOfDay(for: spendDay) }) else {
            return XCTFail("Expected a point for the spend day")
        }
        XCTAssertEqual(spendPoint.variableSpend, 25)

        // Every other day in the window has zero variable spend.
        for point in points where point.day != calendar.startOfDay(for: spendDay) {
            XCTAssertEqual(point.variableSpend, 0)
        }
    }

    func testSpendChartWindowDailyLimitMatchesDailyLimitCalculatorAsOfEachDay() {
        // Spot-check that each point's dailyLimit is exactly
        // DailyLimitCalculator.dailyLimit(asOf: point.day).limit — confirming
        // spendChartWindow reuses that function rather than recomputing its own copy
        // (STANDARDS.md §3).
        let effectiveStartDate = day(-5)
        let input = makeInput(
            effectiveStartDate: effectiveStartDate,
            dailyBase: 10,
            spendEntries: [GoalCarryForwardInput.SpendEntry(date: day(-3), amount: 40, kind: .variable)]
        )

        let points = GoalsScreenCalculator.spendChartWindow(input: input, windowEnd: today, calendar: calendar)
        for point in points {
            let expectedLimit = DailyLimitCalculator.dailyLimit(for: input, asOf: point.day, calendar: calendar).limit
            XCTAssertEqual(point.dailyLimit, expectedLimit, "Mismatch on \(point.day)")
        }
    }

    // MARK: Standard 30-day case / "shorter of 30 days or since goal start"

    func testSpendChartWindowUsesFullThirtyDaysForGoalOlderThanThirtyDays() {
        let input = makeInput(effectiveStartDate: day(-100))
        let points = GoalsScreenCalculator.spendChartWindow(input: input, windowEnd: today, calendar: calendar)
        XCTAssertEqual(points.count, 30)
    }

    func testSpendChartWindowUsesShorterHistorySinceGoalStartWhenGoalIsYoungerThanThirtyDays() {
        // effectiveStartDate 12 days before windowEnd => 13 days of history, well under
        // the 30-day cap, so the window is exactly that history, not padded/truncated.
        let effectiveStartDate = day(-12)
        let input = makeInput(effectiveStartDate: effectiveStartDate)
        let points = GoalsScreenCalculator.spendChartWindow(input: input, windowEnd: today, calendar: calendar)
        XCTAssertEqual(points.count, 13)
        XCTAssertEqual(points.first?.day, calendar.startOfDay(for: effectiveStartDate))
        XCTAssertEqual(points.last?.day, calendar.startOfDay(for: today))
    }

    // MARK: `for goal:` convenience overload wiring

    func testSpendChartWindowForGoalOverloadDerivesInputFromGoal() throws {
        let goal = makeGoal(startDate: day(-5), dailyBase: 10, createdAt: day(-5))
        makeTransaction(amount: 15, date: day(-2), type: .variable, savingsGoal: goal)
        try context.save()

        let viaOverload = GoalsScreenCalculator.spendChartWindow(for: goal, windowEnd: today, calendar: calendar)
        let viaInput = GoalsScreenCalculator.spendChartWindow(
            input: TodayScreenCalculator.carryForwardInput(for: goal, calendar: calendar),
            windowEnd: today,
            calendar: calendar
        )
        XCTAssertEqual(viaOverload, viaInput)
        XCTAssertEqual(viaOverload.count, 6)
        XCTAssertEqual(viaOverload.first(where: { $0.day == calendar.startOfDay(for: day(-2)) })?.variableSpend, 15)
    }
}
