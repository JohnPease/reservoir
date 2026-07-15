#if DEBUG
import SwiftUI

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
    @State private var showingProductionConfirmation = false

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
                .confirmationDialog(
                    "Switch to Production?",
                    isPresented: $showingProductionConfirmation,
                    titleVisibility: .visible,
                    presenting: pendingEnvironment
                ) { candidate in
                    Button("Switch to \(candidate.displayName)", role: .destructive) {
                        applyEnvironment(candidate)
                    }
                    .accessibilityIdentifier("plaidDebug.confirmProductionSwitch")
                    Button("Cancel", role: .cancel) {
                        pendingEnvironment = nil
                    }
                    .accessibilityIdentifier("plaidDebug.cancelProductionSwitch")
                } message: { _ in
                    Text("This will use real bank data. Only continue if you intend to link a real account.")
                }

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
                            Text(error.userFacingMessage)
                                .foregroundStyle(.red)
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
            }
            .navigationTitle("Plaid (Debug)")
            .plaidLinkPresentation(service: service)
        }
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
                    showingProductionConfirmation = true
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
