import SwiftUI
import LinkKit

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

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $service.isPresentingLink) {
                if let session = service.linkSession {
                    session.sheet()
                }
            }
    }
}

extension View {
    func plaidLinkPresentation(service: PlaidServiceLive) -> some View {
        modifier(PlaidLinkPresentationModifier(service: service))
    }
}
