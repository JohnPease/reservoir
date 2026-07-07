import SwiftUI

struct RootTabView: View {
    var body: some View {
        TabView {
            Text("Today")
                .tabItem { Label("Today", systemImage: "sun.max") }

            Text("Goals")
                .tabItem { Label("Goals", systemImage: "target") }

            Text("Transactions")
                .tabItem { Label("Transactions", systemImage: "list.bullet") }

            Text("Settings")
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}
