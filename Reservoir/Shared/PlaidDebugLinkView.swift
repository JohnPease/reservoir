#if DEBUG
import SwiftUI

/// Temporary, debug-only entry point for exercising the Plaid Link +
/// Keychain flow built in reservoir-adq.6.1. Settings (reservoir-adq.7) owns
/// the real "Link a bank account" entry point in the shipped app — this view
/// exists only so the flow can be driven and verified end to end before that
/// story exists, and should be removed once adq.7 ships (see reservoir-
/// adq.6.1's UX section, "Entry point").
struct PlaidDebugLinkView: View {
    @State private var service = PlaidServiceLive()
    @State private var verifiedTokenMessage: String?

    var body: some View {
        NavigationStack {
            Form {
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
                        verifiedTokenMessage = Self.verifyTokenStored()
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

    /// Reads the stored token back out of Keychain directly — the manual
    /// check called for by reservoir-adq.6.1's acceptance criteria ("verified
    /// by reading it back"). Never displays the token itself, only whether
    /// one is present.
    private static func verifyTokenStored() -> String {
        let keychain = KeychainService()
        do {
            if let token = try keychain.read(for: PlaidKeychainKey.accessToken), !token.isEmpty {
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
