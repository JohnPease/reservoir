import SwiftUI
import SwiftData
import UIKit

/// Identifies each of `RootTabView`'s tabs, so its `TabView` can bind `selection:` to
/// `TabSelection.selected` below rather than relying on index-based selection. Originally
/// added (reservoir-adq.6.5) so `TodayView`'s connection-status badge could programmatically
/// switch to Settings on tap; that badge moved onto the Settings tab item itself as a
/// native `.badge(_:)` (code review follow-up on reservoir-adq.7), so `TodayView` no longer
/// consumes this — `RootTabView`'s own `selection:` binding is the sole remaining consumer.
enum AppTab: Hashable {
    case today, goals, transactions, settings
}

/// The one shared, `@Observable` tab-selection binding — owned by `RootTabView`, injected
/// down to every tab via `.environment(_:)` (same idiom as `TodayClock`/
/// `TransactionImportService`). Backs `RootTabView`'s own `TabView(selection:)` binding;
/// no other view currently reads it (`TodayView`'s prior consumption, described in
/// `AppTab`'s doc comment above, was removed).
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

    /// Keeps the home screen widget's App Group snapshot current (reservoir-apd). Owned
    /// here, above the tabs, so it works whichever tab is showing; a no-op under tests.
    @State private var widgetPublisher: WidgetSnapshotPublishing = WidgetSnapshotPublisher.makeDefault()

    var body: some View {
        // Wide and short (landscape on either display): a side rail replaces the tab bar, which
        // would cost a sixth of a 466 pt tall screen (reservoir-wrx). The `TabView` stays in the
        // same place in the tree either way, so each tab keeps its state across a rotation or fold.
        GeometryReader { proxy in
            let showsRail = ScreenLayout.layout(for: proxy.size) == .panes
            HStack(spacing: 0) {
                if showsRail {
                    SideRail(
                        selection: Bindable(tabSelection).selected,
                        settingsNeedsAttention: importService?.needsAttention == true
                    )
                    Divider()
                }
                tabs(hidesTabBar: showsRail)
            }
        }
        .background(Color("ReservoirBackground").ignoresSafeArea())
        // §3.6: active tab icon/label tinted ReservoirAccent (`.tint` colors whichever
        // tab item is currently selected); inactive tabs' `ReservoirTextMuted` tint is
        // set once via `UITabBar.appearance()` in `.task` below — SwiftUI's `TabView`
        // has no direct modifier for the unselected-item color. The pill-shaped
        // `ReservoirSurfaceAccent` background behind the active tab item is NOT
        // applied here: stock `TabView` (pre-Liquid-Glass tab bar) has no public API
        // for a per-item selection background, and the correct-but-heavyweight fix
        // (a fully custom bottom bar replacing `TabView` outright) was assessed and
        // rejected as disproportionate for this app; won't-fix, see reservoir-d2s.
        .tint(Color("ReservoirAccent"))
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
                    urlSession: UITestScenario.plaidURLSession,
                    postLinkBackoff: UITestScenario.postLinkBackoff ?? TransactionImportService.defaultPostLinkBackoff
                )
            }
            // Set once per launch (idempotent to set repeatedly, but only needs to run
            // once) — UIKit's tab-bar appearance proxy is the only way to color the
            // *unselected* tab items; SwiftUI's `.tint(_:)` above only reaches the
            // selected one. Reads the asset catalog color, not a hardcoded value, so
            // light/dark switching still comes from the Asset Catalog per
            // `docs/DESIGN_STANDARDS.md` §1.
            UITabBar.appearance().unselectedItemTintColor = UIColor(named: "ReservoirTextMuted")
            // Cold launch after an upgrade: the one-time account backfill is owed but no
            // scene-phase transition will trigger it (reservoir-0fq).
            requestWidgetRefresh()
            await importService?.runAccountBackfillIfNeeded()
        }
        .onChange(of: scenePhase) { _, newPhase in
            Task { await importService?.handleScenePhaseTransition(to: newPhase) }
            if newPhase == .active { requestWidgetRefresh() }
        }
        // Widget snapshot triggers: first launch / import service ready, backfill
        // finishing, the midnight tick, and any SwiftData save (transaction, goal,
        // budget or account-selection edits, import completion).
        .onChange(of: importService?.isAccountBackfillComplete) { requestWidgetRefresh() }
        .onChange(of: todayClock.referenceDate) { requestWidgetRefresh() }
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { _ in
            requestWidgetRefresh()
        }
        .onOpenURL { url in
            if WidgetDeepLink.isToday(url) { tabSelection.selected = .today }
        }
    }

    private func tabs(hidesTabBar: Bool) -> some View {
        TabView(selection: Bindable(tabSelection).selected) {
            TodayView()
                .toolbar(hidesTabBar ? .hidden : .automatic, for: .tabBar)
                .tabItem { Label("Today", systemImage: "sun.max") }
                .tag(AppTab.today)

            GoalsView()
                .toolbar(hidesTabBar ? .hidden : .automatic, for: .tabBar)
                .tabItem { Label("Plans", systemImage: "target") }
                .tag(AppTab.goals)

            TransactionsView()
                .toolbar(hidesTabBar ? .hidden : .automatic, for: .tabBar)
                .tabItem { Label("Transactions", systemImage: "list.bullet") }
                .tag(AppTab.transactions)

            SettingsView()
                .toolbar(hidesTabBar ? .hidden : .automatic, for: .tabBar)
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppTab.settings)
                // A broken bank connection (adq.6.5's needsAttention) now surfaces as a
                // native tab-bar badge instead of a separate gear-icon overlay on the
                // Today screen (code review follow-up, reservoir-adq.7) — Settings already
                // has its own tab-bar entry point, so a second, redundant navigation
                // affordance on Today added nothing; only the status signal itself was
                // worth keeping, and a badge on the tab that actually owns this state is
                // the more direct place for it.
                .badge(importService?.needsAttention == true ? "!" : nil)
        }
    }

    private func requestWidgetRefresh() {
        widgetPublisher.requestRefresh(
            modelContext: modelContext,
            isAccountBackfillComplete: importService?.isAccountBackfillComplete ?? true
        )
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

/// The landscape replacement for the tab bar (reservoir-wrx): the same four destinations in a
/// narrow column at the left edge, so the full height goes to the screen's content.
private struct SideRail: View {
    @Binding var selection: AppTab
    let settingsNeedsAttention: Bool

    private static let items: [(tab: AppTab, title: String, symbol: String, id: String)] = [
        (.today, "Today", "sun.max", "rail.today"),
        (.goals, "Plans", "target", "rail.plans"),
        (.transactions, "Transactions", "list.bullet", "rail.transactions"),
        (.settings, "Settings", "gearshape", "rail.settings")
    ]

    var body: some View {
        VStack(spacing: 6) {
            ForEach(Self.items, id: \.tab) { item in
                let isSelected = selection == item.tab
                Button { selection = item.tab } label: {
                    VStack(spacing: 4) {
                        Image(systemName: item.symbol)
                            .font(.title3)
                            .overlay(alignment: .topTrailing) {
                                if item.tab == .settings && settingsNeedsAttention {
                                    Circle().fill(Color("ReservoirDeficit")).frame(width: 9, height: 9).offset(x: 5, y: -3)
                                }
                            }
                        Text(item.title)
                            .font(.caption2)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(isSelected ? Color("ReservoirAccent") : Color("ReservoirTextMuted"))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(isSelected ? Color("ReservoirSurfaceAccent") : .clear, in: RoundedRectangle(cornerRadius: 12))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.tab == .settings && settingsNeedsAttention ? "Settings, needs attention" : item.title)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityIdentifier(item.id)
            }
            Spacer()
        }
        .padding(8)
        .frame(width: 96)
        .background(Color("ReservoirBackground"))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rail")
    }
}
