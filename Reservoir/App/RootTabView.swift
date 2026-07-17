import SwiftUI

struct RootTabView: View {
    /// Owns the app's one shared `TodayClock`, kept current by the one
    /// `ReferenceDateKeeper` applied below — see `TodayClock`'s doc comment for why this
    /// replaced each tab independently scheduling its own midnight-refresh `Task`.
    @State private var todayClock = TodayClock()
    private let calendar: Calendar = .current

    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    /// The app's one shared `TransactionImportService` instance (adq.6.4) — constructed
    /// lazily in `.task` once `modelContext` (an `@Environment` value) is available, same
    /// convention `PlaidDebugLinkView` used for its own now-removed copy. Consolidating
    /// onto a single instance here (rather than one per tab/debug view) means exactly one
    /// `mergeQueue`/`isImporting` for the whole app, injected down to every tab that needs
    /// it via `.environment(_:)` below, instead of three independent import paths racing
    /// against the same persisted store.
    @State private var importService: TransactionImportService?

    var body: some View {
        TabView {
            TodayView()
                .tabItem { Label("Today", systemImage: "sun.max") }

            GoalsView()
                .tabItem { Label("Goals", systemImage: "target") }

            TransactionsView()
                .tabItem { Label("Transactions", systemImage: "list.bullet") }

            #if DEBUG
            // Temporary stand-in for Settings (reservoir-adq.7, not yet
            // built) so the Plaid Link + Keychain flow (reservoir-adq.6.1)
            // can be driven end to end. Remove once adq.7 ships the real
            // Settings tab with its own "Link a bank account" entry point.
            PlaidDebugLinkView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
            #else
            Text("Settings")
                .tabItem { Label("Settings", systemImage: "gearshape") }
            #endif
        }
        .keepingReferenceDateCurrent($todayClock.referenceDate, calendar: calendar)
        .environment(todayClock)
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
    /// `PlaidDebugLinkView` (adq.6.4) so a merge prompt surfaced by a foreground- or
    /// pull-to-refresh-triggered import shows up regardless of which tab is active.
    private var mergeDecisionBinding: Binding<TransactionImportService.PendingMergeDecision?> {
        Binding(
            get: { importService?.pendingMergeDecision },
            set: { _ in }
        )
    }
}
