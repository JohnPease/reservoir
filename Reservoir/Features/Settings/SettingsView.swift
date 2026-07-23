import SwiftUI
import SwiftData

/// The Settings tab (reservoir-adq.7) — owns linked-account management only: the Plaid
/// Link entry point, relink, unlink, and the Sandbox/Production environment toggle. Goal
/// management lives entirely on the Goals tab (adq.5); there is deliberately no
/// starting-balance field here — that's a per-goal value collected at goal creation
/// (`GoalFormView`) and immutable after, not an app-wide setting.
///
/// Replaces the `#if DEBUG`-only `PlaidDebugLinkView`, which stood in for this screen
/// (and the "Transaction import (debug)"/"Keychain verification" scaffolding, neither of
/// which carries any shipped-UX value and isn't reproduced here) until this story shipped.
/// The Environment-picker/confirmation and Plaid-Link/relink/error-display logic below is
/// rebuilt against this view's own state, not copy-pasted — see that file's history for
/// the original.
struct SettingsView: View {
    @State private var service: PlaidServiceLive
    private let environmentStore: PlaidEnvironmentStoring
    @State private var environment: PlaidEnvironment
    @State private var pendingEnvironment: PlaidEnvironment?
    @State private var pendingUnlink: LinkedItem?

    /// The one shared `TransactionImportService` instance, owned by `RootTabView` and
    /// injected via `.environment(_:)` — read here only for `needsAttention` (the
    /// "needs attention" text) and to refresh it immediately after a successful unlink,
    /// same as `onRelinkSuccess` does after a successful relink. This view never calls
    /// `runImport()` itself.
    @Environment(TransactionImportService.self) private var importService: TransactionImportService?

    /// One shared `PlaidEnvironmentStore` instance backs `environmentStore`,
    /// `environment`'s initial value, and `service`'s own environment resolution — see
    /// `PlaidDebugLinkView`'s equivalent `init()` doc comment (PR #12 review finding) for
    /// why a second, independent instance would silently miss the
    /// linked-item/Keychain-invalidation hook `PlaidEnvironmentStore.onChange` fires.
    init() {
        let store = PlaidEnvironmentStore()
        self.environmentStore = store
        self._environment = State(initialValue: store.current)
        self._service = State(initialValue: PlaidServiceLive(
            urlSession: UITestScenario.plaidURLSession,
            environmentStore: store
        ))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Environment") {
                    Picker("Plaid environment", selection: environmentSelection) {
                        ForEach(PlaidEnvironment.allCases, id: \.self) { candidate in
                            Text(candidate.displayName).tag(candidate)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("settings.environmentPicker")

                    Text(environment == .production
                         ? "Using Production credentials — real bank data."
                         : "Using Sandbox credentials — test data only.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .deleteConfirmation(
                    pendingItem: $pendingEnvironment,
                    title: { _ in "Switch to Production?" },
                    message: { _ in "This will use real bank data. Only continue if you intend to link a real account." },
                    actionTitle: { candidate in "Switch to \(candidate.displayName)" },
                    actionAccessibilityIdentifier: "settings.confirmProductionSwitch",
                    cancelAccessibilityIdentifier: "settings.cancelProductionSwitch",
                    onDelete: applyEnvironment
                )

                Section("Linked account") {
                    if let linkedItem = service.linkedItem {
                        LabeledContent("Institution", value: linkedItem.institutionName)
                        LabeledContent("Item ID", value: linkedItem.itemID)

                        // Reuses the shared `PlaidErrorText`/`.itemLoginRequired` copy (not a
                        // second hardcoded string) so this and the Settings tab's own
                        // `.badge(_:)` (RootTabView.swift) never drift into different wording
                        // for the same state. Deliberately
                        // reads `importService?.needsAttention`, not `linkedItem.needsAttention`
                        // — see `PlaidDebugLinkView`'s equivalent (now-removed) comment: the
                        // latter is `PlaidServiceLive`'s own cached copy, which never learns
                        // about an `ITEM_LOGIN_REQUIRED` a *different* service instance
                        // (`TransactionImportService`) detected and wrote straight to the
                        // shared `LinkedItemStore`.
                        if importService?.needsAttention == true {
                            PlaidErrorText(error: .itemLoginRequired)
                                .font(.footnote)
                                .accessibilityIdentifier("settings.needsAttention")
                        }
                    } else {
                        Text("No account linked yet.")
                            .foregroundStyle(.secondary)
                    }

                    if service.isExchangingToken {
                        HStack {
                            ProgressView()
                            Text("Exchanging token…")
                        }
                        .accessibilityIdentifier("settings.exchanging")
                    } else {
                        Button(service.linkedItem == nil ? "Link a bank account" : "Relink") {
                            // "Relink" opens Plaid's update-mode Link for the existing item
                            // (re-authenticates in place, clears needsAttention on success)
                            // rather than startLink(), which would create a duplicate
                            // item/token instead of repairing the existing one.
                            Task {
                                if let linkedItem = service.linkedItem {
                                    await service.startRelink(for: linkedItem)
                                } else {
                                    await service.startLink()
                                }
                            }
                        }
                        .disabled(service.isStartingLink)
                        .accessibilityIdentifier("settings.linkButton")
                    }

                    if let linkedItem = service.linkedItem, !service.isExchangingToken {
                        Button("Unlink", role: .destructive) {
                            pendingUnlink = linkedItem
                        }
                        .disabled(service.isStartingLink)
                        .accessibilityIdentifier("settings.unlinkButton")
                    }

                    if let error = service.presentedError {
                        VStack(alignment: .leading, spacing: 8) {
                            PlaidErrorText(error: error)
                                .accessibilityIdentifier("settings.errorMessage")
                            Button("Try again") {
                                Task { await service.retry() }
                            }
                            .accessibilityIdentifier("settings.tryAgain")
                        }
                    }
                }
                .deleteConfirmation(
                    pendingItem: $pendingUnlink,
                    title: { item in "Unlink \(item.institutionName)?" },
                    message: { _ in
                        "You'll need to go through Plaid's login flow again to reconnect. "
                            + "Transactions already imported will stay."
                    },
                    actionTitle: { _ in "Unlink" },
                    actionAccessibilityIdentifier: "settings.confirmUnlink",
                    cancelAccessibilityIdentifier: "settings.cancelUnlink",
                    onDelete: { _ in
                        Task {
                            await service.unlink()
                            importService?.refreshNeedsAttention()
                        }
                    }
                )
            }
            .navigationTitle("Settings")
            .plaidLinkPresentation(service: service)
        }
        // Wired here (not in init()) because `importService` is an @Environment value —
        // not yet populated at struct init time. Reassigned on every appearance, which is
        // harmless (idempotent) and keeps the closure pointed at whichever
        // TransactionImportService instance is current in the environment. See
        // `PlaidServiceLive.onRelinkSuccess`'s doc comment.
        .onAppear {
            service.onRelinkSuccess = { [importService] in
                importService?.refreshNeedsAttention()
            }
        }
    }

    /// Switching *to* Production requires the confirmation dialog above (real-money blast
    /// radius); switching back to Sandbox is immediate. The `Picker`'s selection binding
    /// intercepts the attempted change rather than applying it directly so Production can
    /// be gated.
    private var environmentSelection: Binding<PlaidEnvironment> {
        Binding(
            get: { environment },
            set: { newValue in
                if newValue == .production {
                    pendingEnvironment = newValue
                } else {
                    applyEnvironment(newValue)
                }
            }
        )
    }

    private func applyEnvironment(_ newValue: PlaidEnvironment) {
        environmentStore.set(newValue)
        environment = newValue
        pendingEnvironment = nil
    }
}
