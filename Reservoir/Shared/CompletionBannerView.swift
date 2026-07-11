import SwiftUI

/// A completed-but-undismissed goal's banner: "reached its target date" framing +
/// dismiss (X) action. Shared between `TodayView` (the original completion banner) and
/// `GoalsView`'s completed-undismissed section, which the bead (adq.5) requires to match
/// "Today's completion-banner content/copy and dismiss (X) action" exactly — extracted
/// here rather than duplicated per STANDARDS.md §3.
///
/// Accessibility identifiers are parameterized so each call site keeps its own existing/
/// expected identifiers for XCUITest (`today.completionBanner`/`today.dismissBanner` vs.
/// `goals.completedCard`/`goals.completedCard.dismiss`).
struct CompletionBannerView: View {
    let goal: SavingsGoal
    let onDismiss: () -> Void
    var containerAccessibilityIdentifier: String = "today.completionBanner"
    var dismissButtonAccessibilityIdentifier: String = "today.dismissBanner"

    /// End-state check (cumulative carry-forward >= 0 through `targetDate`), not merely
    /// that `targetDate` has passed — see `DailyLimitCalculator.isGoalMet` and
    /// reservoir-4za. A day where the user overspent but recovered by the target date
    /// still counts as met.
    private var isGoalMet: Bool {
        TodayScreenCalculator.isGoalMet(goal)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isGoalMet ? "checkmark.circle.fill" : "calendar.badge.clock")
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 4) {
                if isGoalMet {
                    // Celebratory framing: the goal's cumulative carry-forward balance
                    // never went negative through the target date.
                    Text("You reached your goal — nice work!")
                        .font(.headline)
                    Text("Target: \(goal.targetAmount, format: .currency(code: "USD")) by \(goal.targetDate, format: .dateTime.month(.wide).day()).")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    // Factual, non-punitive framing — no shortfall dollar amount, no
                    // guilt language. This is a past event being reported, not an active
                    // warning (see reservoir-4za "UX" section).
                    Text("Your target date has arrived")
                        .font(.headline)
                    Text("You spent more than planned along the way.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .accessibilityIdentifier(dismissButtonAccessibilityIdentifier)
        }
        .padding()
        .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(containerAccessibilityIdentifier)
    }
}
