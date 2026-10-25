import SwiftUI
import LinkKit
import OSLog

/// Presents the active Plaid Link session as a sheet. Unavoidably coupled to
/// `LinkKit`'s presentation API (`PlaidLinkSession.sheet()`) — this is the
/// other file, besides `PlaidServiceLive`, allowed to `import LinkKit`
/// (STANDARDS §4 / reservoir-adq.6.1's acceptance criteria). Depends on the
/// concrete `PlaidServiceLive` rather than the `PlaidService` protocol
/// because it needs the live `PlaidLinkSession` instance, which is
/// intentionally not part of `PlaidService`'s LinkKit-free public surface.
///
/// Apply as a modifier from any view that wants to be able to trigger Link:
/// `.plaidLinkPresentation(service: plaidService)`.
struct PlaidLinkPresentationModifier: ViewModifier {
    @Bindable var service: PlaidServiceLive
    private let logger = Logger(subsystem: "com.reservoir.app", category: "PlaidLinkPresentation")

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $service.isPresentingLink, onDismiss: {
                logger.info("Link sheet dismissed isPresentingLink=\(service.isPresentingLink, privacy: .public)")
            }) {
                if let session = service.linkSession {
                    session.sheet()
                } else {
                    // A presented sheet with no session would be an empty, stuck modal
                    // (reservoir-brn hardening; root cause unproven). Log it and drop the
                    // flag so the Link button isn't left disabled behind a blank sheet.
                    Color.clear.onAppear {
                        logger.error("Link sheet presented without a session; resetting isPresentingLink")
                        service.isPresentingLink = false
                    }
                }
            }
    }
}

extension View {
    func plaidLinkPresentation(service: PlaidServiceLive) -> some View {
        modifier(PlaidLinkPresentationModifier(service: service))
    }
}
