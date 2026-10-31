import XCTest
import SwiftData
@testable import Reservoir

final class WidgetSnapshotTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }()

    private func date(_ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("widget-\(UUID().uuidString).json")
    }

    // MARK: Store

    func testStoreRoundTripsExactDecimals() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FileWidgetSnapshotStore(fileURL: url)
        let snapshot = WidgetSnapshot.sample(now: date(10, 27), calendar: calendar)
        try store.save(snapshot)
        XCTAssertEqual(store.load(), snapshot)
    }

    func testStoreWithoutContainerIsInert() throws {
        let store = FileWidgetSnapshotStore(fileURL: nil)
        try store.save(.sample(now: date(10, 27), calendar: calendar))
        XCTAssertNil(store.load())
    }

    func testStoreRejectsOtherVersion() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        var snapshot = WidgetSnapshot.sample(now: date(10, 27), calendar: calendar)
        snapshot.version = 99
        let store = FileWidgetSnapshotStore(fileURL: url)
        try store.save(snapshot)
        XCTAssertNil(store.load())
    }

    func testStoreMissingFileLoadsNil() {
        XCTAssertNil(FileWidgetSnapshotStore(fileURL: tempURL()).load())
    }

    func testStoreCorruptDataLoadsNil() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not json {".utf8).write(to: url)
        XCTAssertNil(FileWidgetSnapshotStore(fileURL: url).load())
        try Data().write(to: url)
        XCTAssertNil(FileWidgetSnapshotStore(fileURL: url).load())
    }

    func testStoreStructurallyWrongJSONLoadsNil() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"version":1}"#.utf8).write(to: url)
        XCTAssertNil(FileWidgetSnapshotStore(fileURL: url).load())
    }

    func testStoreOverwritesPreviousSnapshot() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FileWidgetSnapshotStore(fileURL: url)
        let first = WidgetSnapshot.sample(now: date(10, 27, 9), calendar: calendar)
        var second = first
        second.generatedAt = date(10, 27, 15)
        try store.save(first)
        try store.save(second)
        XCTAssertEqual(store.load(), second)
    }

    func testStoreSaveToUnwritableLocationThrows() {
        let store = FileWidgetSnapshotStore(fileURL: URL(fileURLWithPath: "/nonexistent-dir-\(UUID().uuidString)/x.json"))
        XCTAssertThrowsError(try store.save(.sample(now: date(10, 27), calendar: calendar)))
    }

    func testSampleTomorrowStartIsNextMidnight() {
        let snapshot = WidgetSnapshot.sample(now: date(10, 27), calendar: calendar)
        XCTAssertEqual(snapshot.tomorrowStart, calendar.startOfDay(for: date(10, 28)))
        XCTAssertEqual(snapshot.version, WidgetSnapshot.currentVersion)
    }

    @MainActor
    func testPublishFailureDoesNotReload() {
        var reloads = 0
        let publisher = WidgetSnapshotPublisher(
            store: FileWidgetSnapshotStore(fileURL: URL(fileURLWithPath: "/nonexistent-dir-\(UUID().uuidString)/x.json")),
            reloadTimelines: { reloads += 1 }, calendar: calendar
        )
        XCTAssertFalse(publisher.publish(.sample(now: date(10, 27), calendar: calendar)))
        XCTAssertEqual(reloads, 0)
    }

    @MainActor
    func testPublishRewritesUnchangedFiguresAfterOneHour() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        var reloads = 0
        let store = FileWidgetSnapshotStore(fileURL: url)
        let publisher = WidgetSnapshotPublisher(store: store, reloadTimelines: { reloads += 1 }, calendar: calendar)
        let first = WidgetSnapshot.sample(now: date(10, 27, 9), calendar: calendar)
        var soon = first
        soon.generatedAt = first.generatedAt.addingTimeInterval(3599)
        var later = first
        later.generatedAt = first.generatedAt.addingTimeInterval(3600)
        XCTAssertTrue(publisher.publish(first))
        XCTAssertFalse(publisher.publish(soon))
        XCTAssertEqual(store.load()?.generatedAt, first.generatedAt)
        XCTAssertTrue(publisher.publish(later))
        XCTAssertEqual(store.load()?.generatedAt, later.generatedAt)
        XCTAssertEqual(reloads, 2)
    }

    @MainActor
    func testRefreshNowBuildsFromStoreAndSkipsUnchanged() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let schema = Schema(versionedSchema: SchemaV10.self)
        let container = try ModelContainer(
            for: schema, migrationPlan: ReservoirMigrationPlan.self,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        context.insert(Budget(monthlyAmount: 3100, startDate: date(10, 27), selectedAccountIDs: ["a"]))
        try context.save()

        var reloads = 0
        let store = FileWidgetSnapshotStore(fileURL: url)
        let publisher = WidgetSnapshotPublisher(store: store, reloadTimelines: { reloads += 1 }, calendar: calendar)
        publisher.refreshNow(modelContext: context, isAccountBackfillComplete: true, now: date(10, 27, 9))
        XCTAssertEqual(store.load()?.today.budget, .active(remaining: 100, limit: 100, spentToday: 0))
        publisher.refreshNow(modelContext: context, isAccountBackfillComplete: true, now: date(10, 27, 9).addingTimeInterval(60))
        XCTAssertEqual(reloads, 1)
        publisher.refreshNow(modelContext: context, isAccountBackfillComplete: false, now: date(10, 27, 9).addingTimeInterval(120))
        XCTAssertEqual(reloads, 2)
        XCTAssertEqual(store.load()?.today.budget, .message(.syncing))
    }

    @MainActor
    func testRequestRefreshDebouncesBurstIntoOneWrite() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let schema = Schema(versionedSchema: SchemaV10.self)
        let container = try ModelContainer(
            for: schema, migrationPlan: ReservoirMigrationPlan.self,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        var reloads = 0
        let publisher = WidgetSnapshotPublisher(
            store: FileWidgetSnapshotStore(fileURL: url), reloadTimelines: { reloads += 1 },
            calendar: calendar, debounce: .milliseconds(50)
        )
        for _ in 0..<5 { publisher.requestRefresh(modelContext: context, isAccountBackfillComplete: true) }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(reloads, 1)
        XCTAssertNotNil(FileWidgetSnapshotStore(fileURL: url).load())
    }

    @MainActor
    func testNoOpPublisherNeverWrites() async throws {
        let context = ModelContext(try ModelContainer(for: Schema(versionedSchema: SchemaV10.self), migrationPlan: ReservoirMigrationPlan.self, configurations: [ModelConfiguration(schema: Schema(versionedSchema: SchemaV10.self), isStoredInMemoryOnly: true)]))
        // Must be inert: no store, no reload, nothing to observe but also no crash.
        NoOpWidgetSnapshotPublisher().requestRefresh(modelContext: context, isAccountBackfillComplete: true)
    }

    @MainActor
    func testEveryUITestEnvironmentVariableSelectsNoOp() {
        for key in ["UITEST_SCENARIO", "UITEST_RESET", "UITEST_ANYTHING"] {
            XCTAssertTrue(WidgetSnapshotPublisher.makeDefault(environment: [key: "1"]) is NoOpWidgetSnapshotPublisher, key)
        }
        XCTAssertTrue(WidgetSnapshotPublisher.makeDefault(environment: ["HOME": "/x"]) is WidgetSnapshotPublisher)
    }

    @MainActor
    func testUITestHelperDisableKeyAndXCTestHostSelectNoOp() {
        let key = WidgetSnapshotPublisher.uiTestDisableKey
        XCTAssertEqual(key, "UITEST_DISABLE_WIDGET_PUBLISH")
        XCTAssertTrue(WidgetSnapshotPublisher.makeDefault(environment: [key: "1"]) is NoOpWidgetSnapshotPublisher)
        XCTAssertTrue(WidgetSnapshotPublisher.isTestProcess(environment: ["XCTestConfigurationFilePath": "/x"]))
        XCTAssertFalse(WidgetSnapshotPublisher.isTestProcess(environment: [:]))
    }

    func testHasSameFiguresIgnoresGeneratedAt() {
        let a = WidgetSnapshot.sample(now: date(10, 27, 9), calendar: calendar)
        var b = a
        b.generatedAt = date(10, 27, 15)
        XCTAssertTrue(a.hasSameFigures(as: b))
        b.today.budget = .notSet
        XCTAssertFalse(a.hasSameFigures(as: b))
    }

    // MARK: Publisher write policy

    func testShouldWriteRules() {
        let existing = WidgetSnapshot.sample(now: date(10, 27, 9), calendar: calendar)
        var sameSoon = existing
        sameSoon.generatedAt = date(10, 27, 9).addingTimeInterval(600)
        var sameLater = existing
        sameLater.generatedAt = date(10, 27, 11)
        var changed = sameSoon
        changed.today.budget = .notSet
        XCTAssertTrue(WidgetSnapshotPublisher.shouldWrite(existing: nil, new: existing, minimumRewriteInterval: 3600))
        XCTAssertFalse(WidgetSnapshotPublisher.shouldWrite(existing: existing, new: sameSoon, minimumRewriteInterval: 3600))
        XCTAssertTrue(WidgetSnapshotPublisher.shouldWrite(existing: existing, new: sameLater, minimumRewriteInterval: 3600))
        XCTAssertTrue(WidgetSnapshotPublisher.shouldWrite(existing: existing, new: changed, minimumRewriteInterval: 3600))
    }

    @MainActor
    func testPublishWritesAndReloadsOnlyWhenNeeded() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        var reloads = 0
        let publisher = WidgetSnapshotPublisher(
            store: FileWidgetSnapshotStore(fileURL: url), reloadTimelines: { reloads += 1 }, calendar: calendar
        )
        let snapshot = WidgetSnapshot.sample(now: date(10, 27), calendar: calendar)
        XCTAssertTrue(publisher.publish(snapshot))
        XCTAssertFalse(publisher.publish(snapshot))
        XCTAssertEqual(reloads, 1)
    }

    @MainActor
    func testDefaultPublisherIsNoOpUnderTests() {
        let publisher = WidgetSnapshotPublisher.makeDefault(environment: ["UITEST_SCENARIO": "normal"])
        XCTAssertTrue(publisher is NoOpWidgetSnapshotPublisher)
        XCTAssertTrue(WidgetSnapshotPublisher.makeDefault(environment: ["XCTestConfigurationFilePath": "x"]) is NoOpWidgetSnapshotPublisher)
        XCTAssertTrue(WidgetSnapshotPublisher.makeDefault(environment: [:]) is WidgetSnapshotPublisher)
    }

    // MARK: Builder

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

    func testBuilderNothingConfigured() {
        let snapshot = build(now: date(10, 27))
        XCTAssertEqual(snapshot.today.budget, .notSet)
        XCTAssertEqual(snapshot.today.savings, .notSet)
        XCTAssertNil(snapshot.today.month)
        XCTAssertEqual(snapshot.tomorrowStart, calendar.startOfDay(for: date(10, 28)))
    }

    func testBuilderBudgetStatesAndFigures() throws {
        let schema = Schema(versionedSchema: SchemaV10.self)
        let container = try ModelContainer(
            for: schema, migrationPlan: ReservoirMigrationPlan.self,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let empty = Budget(monthlyAmount: 3100, startDate: date(10, 1), selectedAccountIDs: [])
        let selected = Budget(monthlyAmount: 3100, startDate: date(10, 1), selectedAccountIDs: ["a"])
        context.insert(empty)
        context.insert(selected)
        let spend = SpendTransaction(
            amount: 40, date: date(10, 27, 9), merchantName: "M", type: .variable, entryMethod: .imported,
            plaidAccountID: "a", savingsGoal: nil
        )
        context.insert(spend)

        XCTAssertEqual(build(budget: empty, now: date(10, 27)).today.budget, .message(.chooseAccounts))
        XCTAssertEqual(build(budget: selected, backfillComplete: false, now: date(10, 27)).today.budget, .message(.syncing))

        let snapshot = build(budget: selected, transactions: [spend], now: date(10, 27))
        guard case .active = snapshot.today.budget.state else { return XCTFail("expected active") }
        XCTAssertEqual(snapshot.today.budget.spentToday, 40)
        XCTAssertEqual(snapshot.tomorrow.budget.spentToday, 0)
        XCTAssertEqual(snapshot.today.month?.monthName, "October")
        XCTAssertEqual(snapshot.today.month?.monthlyAmount, 3100)
        // Tomorrow's remaining carries today's overspend/surplus, with nothing spent on the new day.
        XCTAssertEqual(snapshot.tomorrow.budget.remaining, snapshot.tomorrow.budget.limit)
    }

    func testBuilderSavingsGoalActiveTodayButNotTomorrow() {
        let goal = SavingsGoal(
            targetAmount: 1000, targetDate: date(10, 27), startDate: date(10, 1),
            startingBalance: 0, dailyBase: 10, createdAt: date(10, 1)
        )
        let snapshot = build(goals: [goal], now: date(10, 27))
        XCTAssertEqual(snapshot.today.savings.state, .active)
        XCTAssertEqual(snapshot.tomorrow.savings, .notSet)
    }
}
