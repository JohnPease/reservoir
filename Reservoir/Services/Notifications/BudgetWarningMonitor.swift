import Foundation
import SwiftData

/// Turns "something the budget depends on may have changed" into a budget warning evaluation
/// (reservoir-nka.3): debounced (a burst of saves from an import becomes one evaluation),
/// held back while a sync is running (a half-imported month would warn wrongly) and re-run
/// when the app tells it the sync ended. Foreground only; `RootTabView` owns the triggers.
@MainActor
final class BudgetWarningMonitor {
    private let notifier: BudgetWarningEvaluating
    private let calendar: Calendar
    private let debounce: Duration
    private let accountStore: LinkedAccountStoring
    private let itemStore: LinkedItemStoring
    private let now: () -> Date
    private var pending: Task<Void, Never>?

    init(
        notifier: BudgetWarningEvaluating,
        calendar: Calendar = .autoupdatingCurrent,
        debounce: Duration = .milliseconds(500),
        accountStore: LinkedAccountStoring = LinkedAccountStore(),
        itemStore: LinkedItemStoring = LinkedItemStore(),
        now: @escaping () -> Date = { .now }
    ) {
        self.notifier = notifier
        self.calendar = calendar
        self.debounce = debounce
        self.accountStore = accountStore
        self.itemStore = itemStore
        self.now = now
    }

    /// Schedules an evaluation after the debounce, replacing any pending one. While a sync is
    /// active nothing is scheduled (and a pending evaluation is dropped); the trigger that
    /// fires when the sync ends calls this again with `isSyncActive == false`.
    func requestEvaluation(modelContext: ModelContext, isAccountBackfillComplete: Bool, isSyncActive: Bool) {
        pending?.cancel()
        pending = nil
        guard !isSyncActive else { return }
        pending = Task { [debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await evaluateNow(modelContext: modelContext, isAccountBackfillComplete: isAccountBackfillComplete)
        }
    }

    func evaluateNow(modelContext: ModelContext, isAccountBackfillComplete: Bool) async {
        guard let snapshot = LiveStoreSnapshot.fetch(from: modelContext) else { return }
        let result = Self.currentResult(
            snapshot,
            isAccountBackfillComplete: isAccountBackfillComplete,
            now: now(),
            calendar: calendar,
            accountStore: accountStore,
            itemStore: itemStore
        )
        await notifier.evaluate(result: result, isAccountBackfillComplete: isAccountBackfillComplete)
    }

    /// The recovery result Today's banner is built from; `nil` with no budget or an inactive
    /// card (syncing / choose accounts / not started).
    static func currentResult(
        _ snapshot: LiveStoreSnapshot,
        isAccountBackfillComplete: Bool,
        now: Date,
        calendar: Calendar,
        accountStore: LinkedAccountStoring,
        itemStore: LinkedItemStoring
    ) -> BudgetRecoveryCalculator.Result? {
        BudgetSummaryCalculator.cardModelAndRecoveryInsights(
            budget: snapshot.budget,
            transactions: snapshot.transactions,
            isAccountBackfillComplete: isAccountBackfillComplete,
            referenceDate: now,
            accountStore: accountStore,
            itemStore: itemStore,
            calendar: calendar
        ).insights?.recovery
    }
}
