import SwiftUI

/// Identifies each of `RootTabView`'s tabs — reservoir-adq.6.5 needs a way for
/// `TodayView`'s connection-status badge to programmatically switch to the Settings tab
/// (`SettingsView`, the reconnect-flow host) when tapped, which a bare `TabView` with no
/// `selection:` binding can't do.
enum AppTab: Hashable {
    case today, goals, transactions, settings
}

/// The one shared, `@Observable` tab-selection binding — owned by `RootTabView`, injected
/// down to every tab via `.environment(_:)` (same idiom as `TodayClock`/
/// `TransactionImportService`) so `TodayView` can navigate to `.settings` without
/// `RootTabView` needing to hand it a closure or reach down into a child's state directly.
@Observable
final class TabSelection {
    var selected: AppTab = .today
}

struct RootTabView: View {
    @State private var tabSelection = TabSelection()
    /// Owns the app's one shared `TodayClock`, kept current by the one
    /// `ReferenceDateKeeper` applied below — see `TodayClock`'s doc comment for why this
    /// replaced each tab independently scheduling its own midnight-refresh `Task`.
    @State private var todayClock = TodayClock()
    private let calendar: Calendar = .current

    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    /// The app's one shared `TransactionImportService` instance (adq.6.4) — constructed
    /// lazily in `.task` once `modelContext` (an `@Environment` value) is available, same
    /// convention `SettingsView`'s predecessor (`PlaidDebugLinkView`) used for its own
    /// now-removed copy. Consolidating onto a single instance here (rather than one per
    /// tab/debug view) means exactly one
    /// `mergeQueue`/`isImporting` for the whole app, injected down to every tab that needs
    /// it via `.environment(_:)` below, instead of three independent import paths racing
    /// against the same persisted store.
    @State private var importService: TransactionImportService?

    var body: some View {
        TabView(selection: Bindable(tabSelection).selected) {
            TodayView()
                .tabItem { Label("Today", systemImage: "sun.max") }
                .tag(AppTab.today)

            GoalsView()
                .tabItem { Label("Goals", systemImage: "target") }
                .tag(AppTab.goals)

            TransactionsView()
                .tabItem { Label("Transactions", systemImage: "list.bullet") }
                .tag(AppTab.transactions)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
        .keepingReferenceDateCurrent($todayClock.referenceDate, calendar: calendar)
        .environment(todayClock)
        .environment(tabSelection)
        .environment(importService)
        .mergePromptConfirmation(
            pendingItem: mergeDecisionBinding,
            title: { decision in
                "This looks like a transaction you already added: \(decision.manualTransaction.merchantName), "
                    + "\(decision.manualTransaction.amount.formatted(.currency(code: "USD"))), "
                    + decision.manualTransaction.date.formatted(.dateTime.month(.wide).day().year())
            },
            message: { _ in "Keep as one entry?" },
            mergeAccessibilityIdentifier: "plaidDebug.mergePrompt.merge",
            keepBothAccessibilityIdentifier: "plaidDebug.mergePrompt.keepBoth",
            onMerge: { _ in importService?.resolveMergeDecision(.merge) },
            onKeepBoth: { _ in importService?.resolveMergeDecision(.keepBoth) }
        )
        .task {
            if importService == nil {
                importService = TransactionImportService(
                    modelContext: modelContext,
                    urlSession: UITestScenario.plaidURLSession
                )
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            Task { await importService?.handleScenePhaseTransition(to: newPhase) }
        }
    }

    /// `mergePromptConfirmation`'s `pendingItem` binding, sourced from
    /// `importService.pendingMergeDecision` (the queue's head) rather than its own
    /// `@State` — the queue is the single source of truth, owned by the service. Setting
    /// this binding to `nil` (dismiss-by-swipe) is a deliberate no-op: per adq.6.3's UX
    /// spec, there's no free "Cancel" for a merge prompt, only "Merge"/"Keep both", both of
    /// which pop the queue themselves via `resolveMergeDecision(_:)`. Hoisted here from
    /// `SettingsView`'s predecessor (`PlaidDebugLinkView`, adq.6.4) so a merge prompt
    /// surfaced by a foreground- or pull-to-refresh-triggered import shows up regardless
    /// of which tab is active.
    private var mergeDecisionBinding: Binding<TransactionImportService.PendingMergeDecision?> {
        Binding(
            get: { importService?.pendingMergeDecision },
            set: { _ in }
        )
    }
}
