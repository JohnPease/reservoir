import SwiftUI

struct RootTabView: View {
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
    }
}
