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

    /// Backdrop-plus-glyph pairing per `docs/DESIGN_STANDARDS.md` §3 ("status icons sit on
    /// a circular backdrop using the surface token for that status, tinted with that
    /// status's text token") — same construction as `TransactionRowView`'s
    /// `TransactionDirectionIcon`. "Goal met" reuses the accent (healthy/positive) pair;
    /// "target date arrived without meeting it" reuses the deficit pair, mirroring the
    /// bead's instruction to mirror `TodayView`'s `isOverLimit` pattern for goals behind
    /// schedule/over-target.
    private func iconBackdropColor(isGoalMet: Bool) -> Color {
        Color(isGoalMet ? "ReservoirSurfaceAccent" : "ReservoirSurfaceDeficit")
    }

    private func iconGlyphColor(isGoalMet: Bool) -> Color {
        Color(isGoalMet ? "ReservoirAccent" : "ReservoirDeficit")
    }

    /// Not-met reuses `ReservoirSurfaceDeficit` as a full card background — the same
    /// pairing `TodayView.StatCard` already establishes and verifies for `isOverLimit`.
    /// Met deliberately stays on the neutral `ReservoirSurface` rather than introducing an
    /// unverified `ReservoirSurfaceAccent`-as-full-card-background pairing (that token's
    /// only existing use is as a small icon backdrop, §2's contrast rule requires
    /// verifying any new background/text pairing before introducing it) — the accent
    /// icon backdrop above already signals "success" without needing the whole card
    /// recolored too.
    private func cardBackgroundColor(isGoalMet: Bool) -> Color {
        Color(isGoalMet ? "ReservoirSurface" : "ReservoirSurfaceDeficit")
    }

    var body: some View {
        // End-state check (cumulative carry-forward >= 0 through `targetDate`), not merely
        // that `targetDate` has passed — see `DailyLimitCalculator.isGoalMet` and
        // reservoir-4za. A day where the user overspent but recovered by the target date
        // still counts as met. Computed once per render (rather than as a computed
        // property re-derived by each of the three color helpers below) since `goal` can
        // vary across renders and this must stay a pure, fresh-per-render calculation.
        let isGoalMet = TodayScreenCalculator.isGoalMet(goal)
        return HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(iconBackdropColor(isGoalMet: isGoalMet))
                Image(systemName: isGoalMet ? "checkmark.circle.fill" : "calendar.badge.clock")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(iconGlyphColor(isGoalMet: isGoalMet))
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 4) {
                if isGoalMet {
                    // Celebratory framing: the goal's cumulative carry-forward balance
                    // never went negative through the target date.
                    Text("You reached your goal — nice work!")
                        .font(.headline)
                        .foregroundStyle(Color("ReservoirTextPrimary"))
                    Text("Target: \(goal.targetAmount, format: .currency(code: "USD")) by \(goal.targetDate, format: .dateTime.month(.wide).day()).")
                        .font(.subheadline)
                        .foregroundStyle(Color("ReservoirTextSecondary"))
                } else {
                    // Factual, non-punitive framing — no shortfall dollar amount, no
                    // guilt language. This is a past event being reported, not an active
                    // warning (see reservoir-4za "UX" section).
                    Text("Your target date has arrived")
                        .font(.headline)
                        .foregroundStyle(Color("ReservoirDeficit"))
                    Text("You spent more than planned along the way.")
                        .font(.subheadline)
                        .foregroundStyle(Color("ReservoirTextSecondary"))
                }
            }
            Spacer()
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(Color("ReservoirTextSecondary"))
            }
            .accessibilityIdentifier(dismissButtonAccessibilityIdentifier)
        }
        .padding()
        .background(cardBackgroundColor(isGoalMet: isGoalMet), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(containerAccessibilityIdentifier)
    }
}
