import SwiftUI

/// Shared minimal stub for flows not yet built out — currently just the Today screen
/// header's settings icon (Settings tab is a future story's scope). Needs a real entry
/// point to lay out and test now, but the actual destination is out of scope here.
///
/// Originally collapsed from three structurally identical views
/// (`AddTransactionStubSheet`, `CreateGoalStubSheet`, `SettingsStubSheet`) that differed
/// only in their string literals — STANDARDS.md §3 ("no copy-paste"). `CreateGoalStubSheet`
/// was retired in adq.5: goal creation now opens the real `GoalFormView` from both
/// `TodayView` and `GoalsView`, not this stub. `AddTransactionStubSheet` was retired in
/// adq.3: `TodayView`'s "Add transaction" sheet now opens the real `TransactionEntryView`.
/// `StubSheet` itself stays for Settings, still future-story scope.
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
