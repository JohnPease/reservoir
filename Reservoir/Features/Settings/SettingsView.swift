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
    /// injected via `.environment(_:)` — read here only to refresh it immediately after a
    /// successful unlink/relink, same as `onRelinkSuccess` does. This view never calls
    /// `runImport()` itself. Its own `needsAttention` (an OR across every linked item,
    /// reservoir-adq.6.5/loc.2) still backs `RootTabView`'s tab badge, but each row below
    /// reads its own item's `needsAttention` directly (reservoir-loc.3) rather than this
    /// service's app-wide OR.
    @Environment(TransactionImportService.self) private var importService: TransactionImportService?

    /// Needed only to call `GoalAccountAssociationService.dissociate(itemID:modelContext:)`
    /// as part of unlinking an item (reservoir-loc.3) — this view had no `ModelContext`
    /// dependency before, since unlink previously only touched `LinkedItemStore`/Keychain
    /// via `PlaidServiceLive`, neither of which needs SwiftData.
    @Environment(\.modelContext) private var modelContext

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
                        .foregroundStyle(Color("ReservoirTextSecondary"))
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

                // Rebuilt for reservoir-loc.3: an unbounded `ForEach` over every linked
                // item (via `service.linkedItems`), each with its own relink/unlink/
                // needsAttention state, replacing the old single `if let linkedItem`
                // section. No fixed cap — "Link another account" stays available
                // regardless of how many items are already linked.
                //
                // Accessibility identifiers are now per-item (`settings.relinkButton.
                // <itemID>` etc.) rather than the old single static
                // `settings.linkButton`/`settings.unlinkButton`/`settings.needsAttention` —
                // `ReservoirUITests/PlaidRelinkUITests.swift` predates this story and still
                // targets the old single-item identifiers/assumptions (e.g. "linkButton's
                // label switches between Relink/Link a bank account"), which no longer
                // holds now that adding and relinking are two permanently-separate
                // affordances. That suite needs a rewrite pass for the new multi-item
                // shape — flagged, not silently left broken.
                Section("Linked accounts") {
                    if service.linkedItems.isEmpty {
                        Text("No account linked yet.")
                            .foregroundStyle(Color("ReservoirTextSecondary"))
                    } else {
                        ForEach(service.linkedItems, id: \.itemID) { item in
                            LinkedAccountRow(
                                item: item,
                                isStartingLink: service.isStartingLink,
                                onRelink: {
                                    // "Relink" opens Plaid's update-mode Link for this
                                    // specific item (re-authenticates in place, clears
                                    // needsAttention on success) rather than startLink(),
                                    // which would create a duplicate item/token instead of
                                    // repairing the existing one.
                                    Task { await service.startRelink(for: item) }
                                },
                                onUnlink: { pendingUnlink = item }
                            )
                        }
                    }

                    if service.isExchangingToken {
                        HStack {
                            ProgressView()
                            Text("Exchanging token…")
                                .foregroundStyle(Color("ReservoirTextPrimary"))
                        }
                        .accessibilityIdentifier("settings.exchanging")
                    } else {
                        Button {
                            Task { await service.startLink() }
                        } label: {
                            Text("Link another account")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(ReservoirPrimaryButtonStyle())
                        .listRowInsets(EdgeInsets())
                        // Clears the section's `ReservoirSurface` row background just for
                        // this row — the button style already paints its own
                        // `ReservoirAccent` fill, so stacking `ReservoirSurface` behind it
                        // would show as a mismatched border around the button's rounded
                        // corners.
                        .listRowBackground(Color("ReservoirBackground"))
                        .disabled(service.isStartingLink)
                        .accessibilityIdentifier("settings.linkButton")
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
                            + "Transactions already imported will stay. The connection itself "
                            + "still exists on Plaid's side until removed there separately — "
                            + "this only removes it from this app."
                    },
                    actionTitle: { _ in "Unlink" },
                    actionAccessibilityIdentifier: "settings.confirmUnlink",
                    cancelAccessibilityIdentifier: "settings.cancelUnlink",
                    onDelete: { item in
                        Task {
                            // Auto-dissociate before unlink (JP, reservoir-loc.3): an
                            // unlinked item's `itemID` must never linger in any goal's
                            // `associatedItemIDs` — a stale reference there would be a
                            // silent, permanent mismatch (`GoalAccountAssociationService
                            // .associatedGoal` simply never matching anything real again).
                            // Runs before `service.unlink(_:)` so the local-data cleanup
                            // happens before the Keychain/LinkedItemStore cleanup. Failure
                            // here (rare — same `PersistenceSaveHelper.saveOrRollback`
                            // failure mode as any other save) is logged by the service
                            // itself and otherwise swallowed: no dedicated alert channel
                            // for it, since a stale itemID self-heals the next time the
                            // affected goal's account section is retoggled, and adding a
                            // second failure-surfacing path to this view for a rare,
                            // self-healing, non-destructive edge case isn't worth the
                            // added UI surface.
                            _ = GoalAccountAssociationService.dissociate(itemID: item.itemID, modelContext: modelContext)
                            await service.unlink(item)
                            importService?.refreshNeedsAttention()
                        }
                    }
                )
            }
            .scrollContentBackground(.hidden)
            .listRowBackground(Color("ReservoirSurface"))
            .background(Color("ReservoirBackground"))
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
            // Bug fix (JP, reservoir-loc.3): `service` is this view's own long-lived
            // `PlaidServiceLive` instance, constructed once in `init()`. Its `linkedItems`
            // only updates in response to its own mutation methods — it has no reactive
            // subscription to `LinkedItemStore`, so a write from a *different*
            // `LinkedItemStoring`-backed object (e.g. `TransactionImportService` flagging
            // `ITEM_LOGIN_REQUIRED` mid-import while the user was on another tab) left this
            // view showing a stale snapshot on return. Re-reading on every appearance
            // (harmless if nothing changed, same idempotent posture as the
            // `onRelinkSuccess` wiring above) fixes that.
            service.refreshLinkedItems()
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

/// One row in `SettingsView`'s "Linked accounts" list (reservoir-loc.3) — institution
/// name, this item's own `needsAttention` badge, and its own Relink/Unlink actions.
/// Extracted out of `SettingsView.body` (rather than inlined in the `ForEach`) purely for
/// readability at this nesting depth; it has no reuse elsewhere and takes no dependency
/// beyond what its caller already has in scope.
///
/// Reads `item.needsAttention` directly — unlike the pre-loc.3 single-item section, which
/// deliberately read `importService?.needsAttention` instead of `linkedItem.needsAttention`
/// because that scalar was `TransactionImportService`'s own fresher, live-checked copy (see
/// that property's doc comment). Now that `needsAttention` is genuinely per-item data
/// (`LinkedItemStore`), each row can read its own item's flag directly — `service.linkedItems`
/// is itself sourced from `LinkedItemStore.loadAll()` (refreshed on every relevant mutation,
/// including `TransactionImportService.refreshNeedsAttention()`'s writes, since both go
/// through the same `LinkedItemStoring` instance), so there's no second, staler copy to
/// prefer over it here.
private struct LinkedAccountRow: View {
    let item: LinkedItem
    let isStartingLink: Bool
    let onRelink: () -> Void
    let onUnlink: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Institution", value: item.institutionName)
            LabeledContent("Item ID", value: item.itemID)

            // Reuses the shared `PlaidErrorText`/`.itemLoginRequired` copy (not a second
            // hardcoded string) so this and `RootTabView`'s tab badge never drift into
            // different wording for the same state.
            if item.needsAttention {
                PlaidErrorText(error: .itemLoginRequired)
                    .font(.footnote)
                    .accessibilityIdentifier("settings.needsAttention.\(item.itemID)")
            }

            HStack {
                Button("Relink", action: onRelink)
                    .disabled(isStartingLink)
                    .accessibilityIdentifier("settings.relinkButton.\(item.itemID)")

                Spacer()

                Button("Unlink", role: .destructive, action: onUnlink)
                    .disabled(isStartingLink)
                    .accessibilityIdentifier("settings.unlinkButton.\(item.itemID)")
            }
        }
        .padding(.vertical, 4)
    }
}
