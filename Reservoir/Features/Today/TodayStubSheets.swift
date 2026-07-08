import SwiftUI

/// Minimal stub for the full "Add transaction" flow (adq.3). The Today screen needs a
/// real entry point to lay out and test now; the actual entry form is that story's own
/// scope, so this deliberately doesn't get built out further here.
struct AddTransactionStubSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Add Transaction",
                systemImage: "plus.circle",
                description: Text("Manual transaction entry is coming in a future story.")
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .accessibilityIdentifier("today.addTransactionSheet")
    }
}

/// Minimal stub for goal creation (adq.5/adq.7), reached from the Today screen's "no
/// active goal" empty state.
struct CreateGoalStubSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Create a Goal",
                systemImage: "target",
                description: Text("Goal creation is coming in a future story.")
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .accessibilityIdentifier("today.createGoalSheet")
    }
}

/// Minimal stub reached from the Today screen header's settings icon. The Settings tab
/// itself is out of this story's scope.
struct SettingsStubSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Settings",
                systemImage: "gearshape",
                description: Text("Settings are coming in a future story.")
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .accessibilityIdentifier("today.settingsSheet")
    }
}
