import XCTest
import SwiftData
@testable import Reservoir

/// Uses a real in-memory `ModelContainer`/`ModelContext`, like `ModelPersistenceTests`,
/// rather than constructing `SavingsGoal`/`SpendTransaction` standalone — SwiftData's
/// inverse-relationship sync (`goal.transactions`) is only reliable once objects are
/// inserted into a context, and `TodayScreenCalculator.carryForwardInput` reads that
/// relationship.
final class TodayScreenCalculatorTests: XCTestCase {

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
        dismissedAt: Date? = nil,
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
            dismissedAt: dismissedAt,
            // Defaults to the goal's own startDate (not the real "now" a bare `.now`
            // default would give), so existing tests exercising `startDate`-anchored
            // carry-forward behavior aren't silently broken by the createdAt floor —
            // see effectiveStartDate's `max(startDate, createdAt)` formula. Tests that
            // specifically cover backdating pass a later `createdAt` explicitly.
            createdAt: createdAt ?? resolvedStartDate
        )
        context.insert(goal)
        return goal
    }

    @discardableResult
    private func makeTransaction(
        amount: Decimal,
        date: Date,
        merchantName: String = "Merchant",
        type: TransactionType = .variable,
        savingsGoal: SavingsGoal? = nil,
        createdAt: Date = .now
    ) -> SpendTransaction {
        let transaction = SpendTransaction(
            amount: amount,
            date: date,
            merchantName: merchantName,
            type: type,
            entryMethod: .manual,
            savingsGoal: savingsGoal,
            createdAt: createdAt
        )
        context.insert(transaction)
        return transaction
    }

    // MARK: - isActive / activeGoals

    func testGoalIsActiveWhenTargetDateIsToday() {
        let goal = makeGoal(targetDate: today)
        XCTAssertTrue(TodayScreenCalculator.isActive(goal, referenceDate: today, calendar: calendar))
    }

    func testGoalIsActiveWhenTargetDateIsInTheFuture() {
        let goal = makeGoal(targetDate: day(1))
        XCTAssertTrue(TodayScreenCalculator.isActive(goal, referenceDate: today, calendar: calendar))
    }

    func testGoalIsNotActiveWhenTargetDateHasPassed() {
        let goal = makeGoal(targetDate: day(-1))
        XCTAssertFalse(TodayScreenCalculator.isActive(goal, referenceDate: today, calendar: calendar))
    }

    func testGoalIsNotActiveOnceDismissedEvenIfTargetDateIsFuture() {
        let goal = makeGoal(targetDate: day(5), dismissedAt: .now)
        XCTAssertFalse(TodayScreenCalculator.isActive(goal, referenceDate: today, calendar: calendar))
    }

    func testActiveGoalsFiltersMixedSet() {
        let active = makeGoal(targetDate: day(1))
        makeGoal(targetDate: day(-1))
        makeGoal(targetDate: day(5), dismissedAt: .now)

        let result = TodayScreenCalculator.activeGoals([active], referenceDate: today, calendar: calendar)
        XCTAssertEqual(result.map(\.persistentModelID), [active.persistentModelID])
    }

    // MARK: - completedUndismissedGoals

    func testCompletedUndismissedGoalsIncludesPastTargetDateWithNoDismissal() {
        let completed = makeGoal(targetDate: day(-1))
        let result = TodayScreenCalculator.completedUndismissedGoals([completed], referenceDate: today, calendar: calendar)
        XCTAssertEqual(result.map(\.persistentModelID), [completed.persistentModelID])
    }

    func testCompletedUndismissedGoalsExcludesAlreadyDismissedGoal() {
        let dismissed = makeGoal(targetDate: day(-1), dismissedAt: .now)
        let result = TodayScreenCalculator.completedUndismissedGoals([dismissed], referenceDate: today, calendar: calendar)
        XCTAssertTrue(result.isEmpty)
    }

    func testCompletedUndismissedGoalsExcludesStillActiveGoal() {
        let active = makeGoal(targetDate: day(1))
        let result = TodayScreenCalculator.completedUndismissedGoals([active], referenceDate: today, calendar: calendar)
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - hasNoGoalsAtAll (shared by TodayView and GoalsView)

    func testHasNoGoalsAtAllIsTrueWhenBothListsAreEmpty() {
        XCTAssertTrue(TodayScreenCalculator.hasNoGoalsAtAll(activeGoals: [], completedUndismissedGoals: []))
    }

    func testHasNoGoalsAtAllIsFalseWhenThereIsAnActiveGoal() {
        let active = makeGoal(targetDate: day(1))
        XCTAssertFalse(TodayScreenCalculator.hasNoGoalsAtAll(activeGoals: [active], completedUndismissedGoals: []))
    }

    func testHasNoGoalsAtAllIsFalseWhenThereIsOnlyACompletedUndismissedGoal() {
        let completed = makeGoal(targetDate: day(-1))
        XCTAssertFalse(TodayScreenCalculator.hasNoGoalsAtAll(activeGoals: [], completedUndismissedGoals: [completed]))
    }

    // MARK: - carryForwardInput mapping

    func testCarryForwardInputUsesLastEditedDateWhenPresent() {
        let edited = day(-3)
        let goal = makeGoal(startDate: day(-10), lastEditedDate: edited)

        let input = TodayScreenCalculator.carryForwardInput(for: goal)
        XCTAssertEqual(input.effectiveStartDate, edited)
    }

    func testCarryForwardInputFallsBackToStartDateWhenNeverEditedAndNotBackdated() {
        // createdAt == startDate (the "goal created today, startDate defaults to today"
        // common case) — max(startDate, createdAt) resolves to startDate either way.
        let start = day(-10)
        let goal = makeGoal(startDate: start, lastEditedDate: nil, createdAt: start)

        let input = TodayScreenCalculator.carryForwardInput(for: goal, calendar: calendar)
        XCTAssertEqual(input.effectiveStartDate, start)
    }

    // MARK: - carryForwardInput mapping (createdAt floor / backdating, adq.5)

    func testCarryForwardInputFloorsAtCreatedAtWhenStartDateIsBackdated() {
        // startDate backdated 14 days before the goal was actually created — createdAt
        // (today) must win, not the backdated startDate, so carry-forward never accrues
        // for days that predate the goal's real existence.
        let backdatedStart = day(-14)
        let createdToday = today
        let goal = makeGoal(startDate: backdatedStart, lastEditedDate: nil, createdAt: createdToday)

        let input = TodayScreenCalculator.carryForwardInput(for: goal, calendar: calendar)
        XCTAssertEqual(input.effectiveStartDate, createdToday)
    }

    func testCarryForwardInputUsesStartDateWhenItIsAfterCreatedAt() {
        // Defensive/shouldn't normally occur via the validated UI flow (startDate is
        // bounded to <= today at creation time, so it can't be after createdAt in
        // practice), but the mapping should still take the max correctly either way.
        let createdEarlier = day(-5)
        let laterStart = day(-2)
        let goal = makeGoal(startDate: laterStart, lastEditedDate: nil, createdAt: createdEarlier)

        let input = TodayScreenCalculator.carryForwardInput(for: goal, calendar: calendar)
        XCTAssertEqual(input.effectiveStartDate, laterStart)
    }

    func testCarryForwardInputLastEditedDateWinsOverCreatedAtFloor() {
        // An edit resets carry-forward outright — lastEditedDate wins even over a
        // createdAt that's later than it, since editing is itself a "goal recreated"
        // event per PROJECT_SPEC "Core mechanic".
        let edited = day(-1)
        let goal = makeGoal(startDate: day(-14), lastEditedDate: edited, createdAt: day(-14))

        let input = TodayScreenCalculator.carryForwardInput(for: goal, calendar: calendar)
        XCTAssertEqual(input.effectiveStartDate, edited)
    }

    func testBackdatedGoalWithZeroTransactionsShowsNoCarryForwardOnCreationDay() throws {
        // A goal backdated 14 days with zero attributed transactions must show
        // carryForward == 0 on creation day (today) — no fabricated windfall from days
        // that predate the goal's real existence, per adq.5's core createdAt rationale.
        let backdatedStart = day(-14)
        let goal = makeGoal(startDate: backdatedStart, dailyBase: 10, createdAt: today)
        try context.save()

        let input = TodayScreenCalculator.carryForwardInput(for: goal, calendar: calendar)
        let carryForward = DailyLimitCalculator.carryForward(for: input, asOf: today, calendar: calendar)
        XCTAssertEqual(carryForward, 0)

        // dailyBase itself still reflects the full backdated-to-target day count (20 days
        // from day(-14) to day(10)) — softer than an equivalent same-day-start goal with
        // the same target/amount, since totalDaysFromStart uses the raw startDate, not
        // the createdAt-floored effectiveStartDate.
        let softerDailyBase = DailyLimitCalculator.dailyBase(
            targetAmount: 1000,
            startingBalance: 0,
            startDate: backdatedStart,
            targetDate: day(10),
            calendar: calendar
        )
        let sameDayDailyBase = DailyLimitCalculator.dailyBase(
            targetAmount: 1000,
            startingBalance: 0,
            startDate: today,
            targetDate: day(10),
            calendar: calendar
        )
        XCTAssertLessThan(softerDailyBase, sameDayDailyBase)
    }

    func testCarryForwardInputMapsSpendEntryKindsAndFields() throws {
        let goal = makeGoal(dailyBase: 25)
        makeTransaction(amount: 12, date: day(-1), type: .variable, savingsGoal: goal)
        makeTransaction(amount: 40, date: day(-1), type: .fixed, savingsGoal: goal)
        try context.save()

        let input = TodayScreenCalculator.carryForwardInput(for: goal)
        XCTAssertEqual(input.dailyBase, 25)
        XCTAssertEqual(input.spendEntries.count, 2)
        XCTAssertTrue(input.spendEntries.contains { $0.amount == 12 && $0.kind == .variable })
        XCTAssertTrue(input.spendEntries.contains { $0.amount == 40 && $0.kind == .fixed })
    }

    // MARK: - isGoalMet

    func testIsGoalMetTrueWhenCumulativeCarryForwardIsNonNegativeAtTargetDate() throws {
        let start = day(-2)
        let target = day(-1)
        let goal = makeGoal(startDate: start, targetDate: target, dailyBase: 10)
        makeTransaction(amount: 5, date: start, type: .variable, savingsGoal: goal) // +5
        makeTransaction(amount: 5, date: target, type: .variable, savingsGoal: goal) // +5
        try context.save()

        XCTAssertTrue(TodayScreenCalculator.isGoalMet(goal, calendar: calendar))
    }

    func testIsGoalMetFalseWhenCumulativeCarryForwardIsNegativeAtTargetDate() throws {
        let start = day(-2)
        let target = day(-1)
        let goal = makeGoal(startDate: start, targetDate: target, dailyBase: 10)
        makeTransaction(amount: 100, date: start, type: .variable, savingsGoal: goal) // -90
        try context.save()

        XCTAssertFalse(TodayScreenCalculator.isGoalMet(goal, calendar: calendar))
    }

    // MARK: - summary

    func testSummaryReturnsNilWithNoActiveGoals() {
        let result = TodayScreenCalculator.summary(
            activeGoals: [],
            allTransactions: [],
            referenceDate: today,
            calendar: calendar
        )
        XCTAssertNil(result)
    }

    func testSummarySumsAcrossMultipleActiveGoalsIndependently() throws {
        let goalA = makeGoal(startDate: day(-2), dailyBase: 10)
        let goalB = makeGoal(startDate: day(-2), dailyBase: 20)
        try context.save()

        let result = try XCTUnwrap(TodayScreenCalculator.summary(
            activeGoals: [goalA, goalB],
            allTransactions: [],
            referenceDate: today,
            calendar: calendar
        ))

        // No spend recorded on either goal: 2 elapsed days each contribute a full
        // dailyBase to carry-forward (10*2=20 for A, 20*2=40 for B), plus today's base.
        XCTAssertEqual(result.dailyBase, 30)
        XCTAssertEqual(result.carriedForward, 60)
        XCTAssertEqual(result.limit, 90)
    }

    func testSummarySpentTodayIncludesOnlyVariableTransactionsDatedToday() throws {
        let goal = makeGoal(startDate: today, dailyBase: 50)
        makeTransaction(amount: 15, date: today, type: .variable, savingsGoal: goal)
        makeTransaction(amount: 100, date: today, type: .fixed, savingsGoal: goal)
        makeTransaction(amount: 999, date: day(-1), type: .variable, savingsGoal: goal)
        try context.save()

        let result = try XCTUnwrap(TodayScreenCalculator.summary(
            activeGoals: [goal],
            allTransactions: goal.transactions,
            referenceDate: today,
            calendar: calendar
        ))

        XCTAssertEqual(result.spentToday, 15)
        XCTAssertEqual(result.remaining, 35)
    }

    func testSummaryIncludesOrphanedTransactionsDatedToday() throws {
        let goal = makeGoal(startDate: today, dailyBase: 50)
        let orphan = makeTransaction(amount: 20, date: today, type: .variable, savingsGoal: nil)
        try context.save()

        let result = try XCTUnwrap(TodayScreenCalculator.summary(
            activeGoals: [goal],
            allTransactions: [orphan],
            referenceDate: today,
            calendar: calendar
        ))

        XCTAssertEqual(result.spentToday, 20)
    }

    func testSummaryExcludesTransactionsBelongingToDismissedInactiveGoal() throws {
        // The inactive goal here is *dismissed*, not just past its target date, so it's
        // correctly excluded from spend-tracking entirely (finding 3's fix only concerns
        // completed-but-*undismissed* goals; a dismissed goal really should be invisible).
        let active = makeGoal(startDate: today, targetDate: day(5), dailyBase: 50)
        let dismissedInactive = makeGoal(startDate: today, targetDate: day(-1), dailyBase: 50, dismissedAt: .now)
        makeTransaction(amount: 30, date: today, type: .variable, savingsGoal: dismissedInactive)
        try context.save()

        let result = try XCTUnwrap(TodayScreenCalculator.summary(
            activeGoals: [active],
            allTransactions: dismissedInactive.transactions,
            referenceDate: today,
            calendar: calendar
        ))

        XCTAssertEqual(result.spentToday, 0)
    }

    // Regression test for review finding 3: a goal whose targetDate has passed but
    // hasn't been dismissed yet must not have its spend silently excluded from
    // spentToday just because it dropped out of activeGoals.
    func testSummaryIncludesTransactionsBelongingToCompletedUndismissedGoal() throws {
        let active = makeGoal(startDate: today, targetDate: day(5), dailyBase: 50)
        let completedUndismissed = makeGoal(startDate: today, targetDate: day(-1), dailyBase: 50)
        makeTransaction(amount: 30, date: today, type: .variable, savingsGoal: completedUndismissed)
        try context.save()

        let result = try XCTUnwrap(TodayScreenCalculator.summary(
            activeGoals: [active],
            completedUndismissedGoals: [completedUndismissed],
            allTransactions: completedUndismissed.transactions,
            referenceDate: today,
            calendar: calendar
        ))

        XCTAssertEqual(result.spentToday, 30)
    }

    // MARK: - spentToday (standalone)

    func testSpentTodayCountsOrphanedTransactionsRegardlessOfAttributedGoals() {
        let orphan = makeTransaction(amount: 20, date: today, type: .variable, savingsGoal: nil)

        let result = TodayScreenCalculator.spentToday(
            allTransactions: [orphan],
            attributedGoals: [],
            referenceDate: today,
            calendar: calendar
        )

        XCTAssertEqual(result, 20)
    }

    func testSpentTodayCountsTransactionsForAttributedGoalsOnly() throws {
        let attributed = makeGoal(dailyBase: 10)
        let notAttributed = makeGoal(dailyBase: 10)
        makeTransaction(amount: 15, date: today, type: .variable, savingsGoal: attributed)
        makeTransaction(amount: 40, date: today, type: .variable, savingsGoal: notAttributed)
        try context.save()

        let result = TodayScreenCalculator.spentToday(
            allTransactions: attributed.transactions + notAttributed.transactions,
            attributedGoals: [attributed],
            referenceDate: today,
            calendar: calendar
        )

        XCTAssertEqual(result, 15)
    }

    func testSummaryRemainingGoesNegativeWhenOverLimit() throws {
        let goal = makeGoal(startDate: today, dailyBase: 10)
        makeTransaction(amount: 25, date: today, type: .variable, savingsGoal: goal)
        try context.save()

        let result = try XCTUnwrap(TodayScreenCalculator.summary(
            activeGoals: [goal],
            allTransactions: goal.transactions,
            referenceDate: today,
            calendar: calendar
        ))

        XCTAssertEqual(result.remaining, -15)
    }

    // MARK: - recentTransactions

    func testRecentTransactionsReturnsMostRecentFirstByDate() {
        let older = makeTransaction(amount: 1, date: day(-2), merchantName: "Older")
        let newer = makeTransaction(amount: 2, date: day(-1), merchantName: "Newer")

        let result = TodayScreenCalculator.recentTransactions(from: [older, newer], limit: 3)
        XCTAssertEqual(result.map(\.merchantName), ["Newer", "Older"])
    }

    func testRecentTransactionsBreaksSameDayTiesByCreationOrder() {
        let sameDay = today
        let createdFirst = makeTransaction(amount: 1, date: sameDay, merchantName: "First", createdAt: day(-1, from: .now))
        let createdSecond = makeTransaction(amount: 2, date: sameDay, merchantName: "Second", createdAt: .now)

        let result = TodayScreenCalculator.recentTransactions(from: [createdFirst, createdSecond], limit: 3)
        XCTAssertEqual(result.map(\.merchantName), ["Second", "First"])
    }

    func testRecentTransactionsRespectsLimit() {
        let transactions = (0..<5).map { offset in
            makeTransaction(amount: Decimal(offset), date: day(-offset), merchantName: "T\(offset)")
        }

        let result = TodayScreenCalculator.recentTransactions(from: transactions, limit: 3)
        XCTAssertEqual(result.count, 3)
    }

    func testRecentTransactionsReturnsEmptyWhenNoneExist() {
        XCTAssertTrue(TodayScreenCalculator.recentTransactions(from: []).isEmpty)
    }
}
