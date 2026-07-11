import SwiftUI

/// The "no active goal yet / create a savings goal" empty state, shared between
/// `TodayView` (the original empty-state entry point) and `GoalsView` (the Goals tab's
/// own zero-goals empty state, per adq.5 — "reuse the copy/spirit, this is a second
/// entry point to the same empty state, do not invent different copy"). Extracted here
/// rather than duplicated per STANDARDS.md §3.
///
/// Accessibility identifiers are parameterized so each call site keeps its own existing/
/// expected identifiers for XCUITest (`today.emptyGoalState`/`today.createGoal` vs.
/// `goals.emptyState`/`goals.createGoal`).
struct NoActiveGoalPromptView: View {
    let onCreateGoal: () -> Void
    var containerAccessibilityIdentifier: String = "today.emptyGoalState"
    var buttonAccessibilityIdentifier: String = "today.createGoal"

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "target")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No active goal yet")
                .font(.headline)
            Text("Create a savings goal to see your daily limit.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Create a goal", action: onCreateGoal)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier(buttonAccessibilityIdentifier)
        }
        .frame(maxWidth: .infinity)
        .padding()
        // .contain keeps the create button queryable as its own element instead of the
        // whole group collapsing into one element under the container's identifier.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(containerAccessibilityIdentifier)
    }
}
