import XCTest
import SwiftData
@testable import Reservoir

@MainActor
private final class RecordingEvaluator: BudgetWarningEvaluating {
    private(set) var calls: [(level: BudgetWarningLevel?, backfill: Bool)] = []
    private(set) var resets = 0
    var isEnabled = true
    @discardableResult
    func evaluate(result: BudgetRecoveryCalculator.Result?, isAccountBackfillComplete: Bool) async
        -> BudgetWarningNotificationPlanner.Decision {
        calls.append((result?.warning.level, isAccountBackfillComplete))
        return .nothing
    }
    func resetBaseline() { resets += 1 }
}

@MainActor
final class BudgetWarningMonitorTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private var context: ModelContext!
    private var container: ModelContainer!
    private let evaluator = RecordingEvaluator()

    override func setUpWithError() throws {
        let schema = Schema(versionedSchema: SchemaV12.self)
        container = try ModelContainer(
            for: schema, migrationPlan: ReservoirMigrationPlan.self,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        context = ModelContext(container)
    }

    private func date(_ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day))!
    }

    private func makeStores() -> (LinkedAccountStoring, LinkedItemStoring) {
        let suite = "BudgetWarningMonitorTests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = UserDefaults(suiteName: suite)!
        return (LinkedAccountStore(defaults: defaults), LinkedItemStore(defaults: defaults))
    }

    private func makeMonitor(debounce: Duration = .milliseconds(50), now: Date? = nil) -> BudgetWarningMonitor {
        let (accounts, items) = makeStores()
        let reference = now ?? date(10, 2)
        return BudgetWarningMonitor(
            notifier: evaluator, calendar: calendar, debounce: debounce,
            accountStore: accounts, itemStore: items, now: { reference }
        )
    }

    /// October budget at 3100 with 3200 spent on the 2nd: point of no return on Oct 2.
    private func insertOverBudget() {
        context.insert(Budget(monthlyAmount: 3100, startDate: date(10, 1), selectedAccountIDs: ["a1"]))
        context.insert(SpendTransaction(
            amount: 3200, date: date(10, 2), merchantName: "M", type: .variable, entryMethod: .imported,
            plaidItemID: "item-1", plaidAccountID: "a1"
        ))
        try? context.save()
    }

    func testBurstOfRequestsEvaluatesOnce() async throws {
        insertOverBudget()
        let monitor = makeMonitor()
        for _ in 0..<5 {
            monitor.requestEvaluation(modelContext: context, isAccountBackfillComplete: true, isSyncActive: false)
        }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(evaluator.calls.count, 1)
        XCTAssertEqual(evaluator.calls.first?.level, .pointOfNoReturn)
    }

    func testSyncActiveDefersAndCancelsPending() async throws {
        insertOverBudget()
        let monitor = makeMonitor()
        monitor.requestEvaluation(modelContext: context, isAccountBackfillComplete: true, isSyncActive: false)
        monitor.requestEvaluation(modelContext: context, isAccountBackfillComplete: true, isSyncActive: true)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(evaluator.calls.isEmpty)
        // The end-of-sync trigger re-evaluates.
        monitor.requestEvaluation(modelContext: context, isAccountBackfillComplete: true, isSyncActive: false)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(evaluator.calls.count, 1)
    }

    func testEvaluateNowPassesBackfillFlagThrough() async {
        insertOverBudget()
        let monitor = makeMonitor()
        await monitor.evaluateNow(modelContext: context, isAccountBackfillComplete: false)
        XCTAssertEqual(evaluator.calls.map(\.backfill), [false])
        await monitor.evaluateNow(modelContext: context, isAccountBackfillComplete: true)
        XCTAssertEqual(evaluator.calls.map(\.backfill), [false, true])
    }

    func testCurrentResultMatchesInsightsForPointOfNoReturn() throws {
        insertOverBudget()
        let (accounts, items) = makeStores()
        let snapshot = try XCTUnwrap(LiveStoreSnapshot.fetch(from: context))
        let result = try XCTUnwrap(BudgetWarningMonitor.currentResult(
            snapshot, isAccountBackfillComplete: true, now: date(10, 2), calendar: calendar,
            accountStore: accounts, itemStore: items
        ))
        XCTAssertEqual(result.warning.level, .pointOfNoReturn)
        let direct = try XCTUnwrap(BudgetSummaryCalculator.insights(
            budget: snapshot.budget, transactions: snapshot.transactions, isAccountBackfillComplete: true,
            referenceDate: date(10, 2), linkedAccounts: [], linkedItems: [], includeRecovery: true, calendar: calendar
        )?.recovery)
        XCTAssertEqual(result, direct)
        XCTAssertEqual(BudgetWarningMonth(containing: result.monthStart, calendar: calendar), BudgetWarningMonth(year: 2026, month: 10))
    }

    func testCurrentResultIsNilWithoutBudget() throws {
        let (accounts, items) = makeStores()
        let snapshot = try XCTUnwrap(LiveStoreSnapshot.fetch(from: context))
        XCTAssertNil(BudgetWarningMonitor.currentResult(
            snapshot, isAccountBackfillComplete: true, now: date(10, 2), calendar: calendar,
            accountStore: accounts, itemStore: items
        ))
    }

    func testDisabledSkipsEvaluationAndScheduling() async throws {
        insertOverBudget()
        evaluator.isEnabled = false
        let monitor = makeMonitor()
        monitor.requestEvaluation(modelContext: context, isAccountBackfillComplete: true, isSyncActive: false)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(evaluator.calls.isEmpty)
        await monitor.evaluateNow(modelContext: context, isAccountBackfillComplete: true)
        XCTAssertTrue(evaluator.calls.isEmpty)
        // Turning it on makes the next request evaluate.
        evaluator.isEnabled = true
        monitor.requestEvaluation(modelContext: context, isAccountBackfillComplete: true, isSyncActive: false)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(evaluator.calls.count, 1)
    }

    func testDisablingBeforeDebounceFiresDropsPendingEvaluation() async throws {
        insertOverBudget()
        let monitor = makeMonitor()
        monitor.requestEvaluation(modelContext: context, isAccountBackfillComplete: true, isSyncActive: false)
        evaluator.isEnabled = false
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(evaluator.calls.isEmpty)
    }

    func testEvaluateNowWithoutBudgetPassesNilResult() async {
        let monitor = makeMonitor()
        await monitor.evaluateNow(modelContext: context, isAccountBackfillComplete: true)
        XCTAssertEqual(evaluator.calls.count, 1)
        XCTAssertNil(evaluator.calls[0].level)
    }
}
