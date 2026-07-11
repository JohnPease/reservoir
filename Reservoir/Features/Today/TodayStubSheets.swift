import SwiftUI

/// Shared minimal stub for flows not yet built out — reached from the Today screen's
/// "Add transaction" button (adq.3 scope) and the header's settings icon (Settings tab,
/// out of this story's scope). Each call site needs a real entry point to lay out and
/// test now, but the actual destination is a future story's own scope, so this
/// deliberately doesn't get built out further here.
///
/// Originally collapsed from three structurally identical views
/// (`AddTransactionStubSheet`, `CreateGoalStubSheet`, `SettingsStubSheet`) that differed
/// only in their string literals — STANDARDS.md §3 ("no copy-paste"). `CreateGoalStubSheet`
/// was retired in adq.5: goal creation now opens the real `GoalFormView` from both
/// `TodayView` and `GoalsView`, not this stub. `StubSheet` itself stays for Add
/// Transaction/Settings, which are still future-story scope.
struct StubSheet: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let icon: String
    let description: String
    let accessibilityIdentifier: String

    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                title,
                systemImage: icon,
                description: Text(description)
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
