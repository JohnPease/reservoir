import SwiftUI

struct RootTabView: View {
    /// Owns the app's one shared `TodayClock`, kept current by the one
    /// `ReferenceDateKeeper` applied below — see `TodayClock`'s doc comment for why this
    /// replaced each tab independently scheduling its own midnight-refresh `Task`.
    @State private var todayClock = TodayClock()
    private let calendar: Calendar = .current

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
    }
}
