import Foundation
import SwiftData
import WidgetKit

/// What `RootTabView` talks to: "something the widget shows may have changed".
@MainActor
protocol WidgetSnapshotPublishing: AnyObject {
    func requestRefresh(modelContext: ModelContext, isAccountBackfillComplete: Bool)
}

/// Used under XCUITest scenarios and unit tests, where writing to the real App Group and
/// reloading the real widget timelines would be a side effect on the host device.
@MainActor
final class NoOpWidgetSnapshotPublisher: WidgetSnapshotPublishing {
    func requestRefresh(modelContext: ModelContext, isAccountBackfillComplete: Bool) {}
}

/// Rebuilds the widget snapshot from the live store and hands it to the widget: debounced
/// (a burst of saves from an import becomes one build), skipped when nothing the widget
/// shows changed, and followed by a timeline reload.
@MainActor
final class WidgetSnapshotPublisher: WidgetSnapshotPublishing {
    private let store: WidgetSnapshotStoring
    private let reloadTimelines: () -> Void
    private let calendar: Calendar
    private let debounce: Duration
    private let minimumRewriteInterval: TimeInterval
    private var pending: Task<Void, Never>?

    init(
        store: WidgetSnapshotStoring = FileWidgetSnapshotStore.appGroup(),
        reloadTimelines: @escaping () -> Void = { WidgetCenter.shared.reloadAllTimelines() },
        calendar: Calendar = .current,
        debounce: Duration = .milliseconds(500),
        minimumRewriteInterval: TimeInterval = 3600
    ) {
        self.store = store
        self.reloadTimelines = reloadTimelines
        self.calendar = calendar
        self.debounce = debounce
        self.minimumRewriteInterval = minimumRewriteInterval
    }

    /// Environment variable every UI-test launch sets (via `XCUIApplication.reservoirApp()`).
    nonisolated static let uiTestDisableKey = "UITEST_DISABLE_WIDGET_PUBLISH"

    /// True for a unit-test host or any UI-test launch (the explicit disable key, or any
    /// other `UITEST_*` variable as a backstop for launches that bypass the shared helper).
    nonisolated static func isTestProcess(environment: [String: String]) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
            || environment[uiTestDisableKey] != nil
            || environment.keys.contains { $0.hasPrefix("UITEST_") }
    }

    /// The real publisher, or the no-op one under unit tests and UI tests.
    static func makeDefault(environment: [String: String] = ProcessInfo.processInfo.environment) -> WidgetSnapshotPublishing {
        isTestProcess(environment: environment) ? NoOpWidgetSnapshotPublisher() : WidgetSnapshotPublisher()
    }

    func requestRefresh(modelContext: ModelContext, isAccountBackfillComplete: Bool) {
        pending?.cancel()
        pending = Task { [debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            refreshNow(modelContext: modelContext, isAccountBackfillComplete: isAccountBackfillComplete)
        }
    }

    func refreshNow(modelContext: ModelContext, isAccountBackfillComplete: Bool, now: Date = .now) {
        guard let goals = try? modelContext.fetch(FetchDescriptor<SavingsGoal>()),
              let budgets = try? modelContext.fetch(FetchDescriptor<Budget>(sortBy: [SortDescriptor(\.createdAt)])),
              let transactions = try? modelContext.fetch(FetchDescriptor<SpendTransaction>())
        else { return }
        let snapshot = WidgetSnapshotBuilder.make(
            goals: goals,
            budget: budgets.first,
            transactions: transactions,
            isAccountBackfillComplete: isAccountBackfillComplete,
            now: now,
            calendar: calendar
        )
        publish(snapshot)
    }

    /// Writes and reloads unless the figures are unchanged and the stored snapshot is
    /// recent. An unchanged-but-old snapshot is rewritten anyway so `generatedAt` (which
    /// drives "Updated <time>" and the staleness rules) reflects the latest launch.
    @discardableResult
    func publish(_ snapshot: WidgetSnapshot) -> Bool {
        guard Self.shouldWrite(existing: store.load(), new: snapshot, minimumRewriteInterval: minimumRewriteInterval)
        else { return false }
        do {
            try store.save(snapshot)
        } catch {
            return false
        }
        reloadTimelines()
        return true
    }

    nonisolated static func shouldWrite(
        existing: WidgetSnapshot?,
        new: WidgetSnapshot,
        minimumRewriteInterval: TimeInterval
    ) -> Bool {
        guard let existing, existing.hasSameFigures(as: new) else { return true }
        return new.generatedAt.timeIntervalSince(existing.generatedAt) >= minimumRewriteInterval
    }
}
