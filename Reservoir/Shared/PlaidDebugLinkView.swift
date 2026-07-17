#if DEBUG
import SwiftUI
import SwiftData

/// Temporary, debug-only entry point for exercising the Plaid Link +
/// Keychain flow built in reservoir-adq.6.1, plus the Sandbox/Production
/// environment toggle built in reservoir-adq.6.2. Settings (reservoir-adq.7)
/// owns the real "Link a bank account" entry point and Sandbox/Production
/// toggle in the shipped app — this view exists only so both flows can be
/// driven and verified end to end before that story exists, and should be
/// removed once adq.7 ships (see reservoir-adq.6.1's UX section, "Entry
/// point").
struct PlaidDebugLinkView: View {
    @State private var service: PlaidServiceLive
    @State private var verifiedTokenMessage: String?
    private let environmentStore: PlaidEnvironmentStoring
    @State private var environment: PlaidEnvironment
    @State private var pendingEnvironment: PlaidEnvironment?

    /// The one shared `TransactionImportService` instance (adq.6.4), owned by
    /// `RootTabView` and injected here via `.environment(_:)` — no longer a standalone
    /// instance constructed by this view (adq.6.3's original, debug-only approach). This
    /// keeps exactly one `mergeQueue`/`isImporting` for the whole app; the debug "Import
    /// transactions" button below just calls `runImport()` against the shared instance,
    /// same as the foreground and pull-to-refresh triggers.
    @Environment(TransactionImportService.self) private var importService: TransactionImportService?

    /// A single shared `PlaidEnvironmentStore` instance backs `environmentStore`,
    /// `environment`'s initial value, and `service`'s own environment
    /// resolution — previously each was seeded from its own separate
    /// `PlaidEnvironmentStore()` instance. Those coincidentally agreed on
    /// *reads* (same `UserDefaults` key underneath), but `PlaidServiceLive`'s
    /// linked-item/Keychain invalidation hook (see `PlaidEnvironmentStore.onChange`)
    /// lives on the specific instance passed to its initializer — with separate
    /// instances, this view calling `.set(_:)` on its own copy would never
    /// have fired that hook on `service`'s copy. One shared instance closes
    /// both gaps (PR #12 review finding).
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
                    .accessibilityIdentifier("plaidDebug.environmentPicker")

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
                    actionAccessibilityIdentifier: "plaidDebug.confirmProductionSwitch",
                    cancelAccessibilityIdentifier: "plaidDebug.cancelProductionSwitch",
                    onDelete: applyEnvironment
                )

                Section("Plaid Link (debug)") {
                    if let linkedItem = service.linkedItem {
                        LabeledContent("Linked institution", value: linkedItem.institutionName)
                        LabeledContent("Item ID", value: linkedItem.itemID)
                    } else {
                        Text("No account linked yet.")
                            .foregroundStyle(.secondary)
                    }

                    if service.isExchangingToken {
                        HStack {
                            ProgressView()
                            Text("Exchanging token…")
                        }
                        .accessibilityIdentifier("plaidDebug.exchanging")
                    } else {
                        Button(service.linkedItem == nil ? "Link a bank account" : "Relink") {
                            Task { await service.startLink() }
                        }
                        .disabled(service.isStartingLink)
                        .accessibilityIdentifier("plaidDebug.linkButton")
                    }

                    if let error = service.presentedError {
                        VStack(alignment: .leading, spacing: 8) {
                            PlaidErrorText(error: error)
                                .accessibilityIdentifier("plaidDebug.errorMessage")
                            Button("Try again") {
                                Task { await service.retry() }
                            }
                            .accessibilityIdentifier("plaidDebug.tryAgain")
                        }
                    }
                }

                Section("Keychain verification") {
                    Button("Verify token stored") {
                        Task { verifiedTokenMessage = await Self.verifyTokenStored() }
                    }
                    .accessibilityIdentifier("plaidDebug.verifyTokenStored")
                    if let verifiedTokenMessage {
                        Text(verifiedTokenMessage)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("plaidDebug.verifyTokenResult")
                    }
                }

                Section("Transaction import (debug)") {
                    if let importService {
                        if importService.isImporting {
                            HStack {
                                ProgressView()
                                Text("Importing…")
                            }
                            .accessibilityIdentifier("plaidDebug.importing")
                        } else {
                            Button("Import transactions") {
                                Task { await importService.runImport() }
                            }
                            .disabled(service.linkedItem == nil)
                            .accessibilityIdentifier("plaidDebug.importButton")
                        }

                        if let summary = importService.lastImportSummary {
                            Text(Self.summaryText(summary))
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("plaidDebug.importSummary")
                        }

                        if let error = importService.presentedError {
                            PlaidErrorText(error: error)
                                .accessibilityIdentifier("plaidDebug.importErrorMessage")
                        }

                        // Always shown (not tap-to-reveal, unlike TransactionsView's
                        // production banner) since this is a debug-only diagnostic
                        // screen — the raw detail is exactly what an engineer using it
                        // wants to see immediately, not an opt-in extra step.
                        if let detail = importService.presentedErrorDetail {
                            Text(detail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .accessibilityIdentifier("plaidDebug.importErrorDetail")
                        }
                    } else {
                        ProgressView()
                    }
                }
            }
            .navigationTitle("Plaid (Debug)")
            .plaidLinkPresentation(service: service)
        }
    }

    private static func summaryText(_ summary: ImportSummary) -> String {
        if summary.isEmpty {
            return "No new transactions."
        }
        var parts: [String] = []
        if summary.added > 0 { parts.append("\(summary.added) new") }
        if summary.modified > 0 { parts.append("\(summary.modified) updated") }
        if summary.removed > 0 { parts.append("\(summary.removed) removed") }
        if summary.queuedForMerge > 0 { parts.append("\(summary.queuedForMerge) awaiting merge decision") }
        return parts.joined(separator: ", ")
    }

    /// Switching *to* Production requires the confirmation dialog above
    /// (real-money blast radius); switching back to Sandbox is immediate.
    /// The `Picker`'s selection binding intercepts the attempted change
    /// rather than applying it directly so Production can be gated.
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

    /// Reads the stored token back out of Keychain directly — the manual
    /// check called for by reservoir-adq.6.1's acceptance criteria ("verified
    /// by reading it back"). Never displays the token itself, only whether
    /// one is present.
    private static func verifyTokenStored() async -> String {
        let keychain = KeychainService()
        do {
            if let token = try await keychain.read(for: PlaidKeychainKey.accessToken), !token.isEmpty {
                return "Token present in Keychain (\(token.count) characters)."
            } else {
                return "No token found in Keychain."
            }
        } catch {
            return "Keychain read failed: \(error)"
        }
    }
}
#endif
