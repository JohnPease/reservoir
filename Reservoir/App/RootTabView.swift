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

            Text("Transactions")
                .tabItem { Label("Transactions", systemImage: "list.bullet") }

            Text("Settings")
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .keepingReferenceDateCurrent($todayClock.referenceDate, calendar: calendar)
        .environment(todayClock)
    }
}
