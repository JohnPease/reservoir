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
        let schema = Schema(versionedSchema: SchemaV2.self)
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
        dismissedAt: Date? = nil
    ) -> SavingsGoal {
        let goal = SavingsGoal(
            targetAmount: targetAmount,
            targetDate: targetDate ?? day(10),
            startDate: startDate ?? day(-10),
            startingBalance: startingBalance,
            dailyBase: dailyBase,
            lastEditedDate: lastEditedDate,
            dismissedAt: dismissedAt
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

    // MARK: - carryForwardInput mapping

    func testCarryForwardInputUsesLastEditedDateWhenPresent() {
        let edited = day(-3)
        let goal = makeGoal(startDate: day(-10), lastEditedDate: edited)

        let input = TodayScreenCalculator.carryForwardInput(for: goal)
        XCTAssertEqual(input.effectiveStartDate, edited)
    }

    func testCarryForwardInputFallsBackToStartDateWhenNeverEdited() {
        let start = day(-10)
        let goal = makeGoal(startDate: start, lastEditedDate: nil)

        let input = TodayScreenCalculator.carryForwardInput(for: goal)
        XCTAssertEqual(input.effectiveStartDate, start)
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
