import SwiftUI
import SwiftData

/// One active goal's card (adq.5): progress bar + percentage, target/start dates, and a
/// per-card "Pace"/"Simulation" segmented control. All math comes from
/// `GoalsScreenCalculator`; this view only renders the structured results and builds the
/// exact copy strings, matching how `TodayView.CompletionBannerView` builds its own copy
/// (STANDARDS.md §3 keeps the underlying math testable without SwiftUI; the literal
/// copy strings themselves are covered by XCUITest, not unit tests, same as Today).
struct ActiveGoalCardView: View {
    let goal: SavingsGoal
    let referenceDate: Date
    let calendar: Calendar
    let onEdit: () -> Void
    let onDelete: () -> Void

    /// Local UI state only, per-card, not persisted — resets to "Pace" (the safe,
    /// always-available default) every time the screen is opened. See bead description's
    /// "per-card segmented control" rationale for why this isn't a single app-wide toggle.
    @State private var selectedSegment: Segment = .pace

    private enum Segment: String, CaseIterable, Identifiable {
        case pace = "Pace"
        case simulation = "Simulation"
        var id: String { rawValue }
    }

    /// `goal.transactions`-derived work each of `clampedProgress`/`progressPercentText`/
    /// `paceText`/`simulationContent` needs, computed once per `body` evaluation instead
    /// of each independently re-deriving it (code-review finding — up to ~4x redundant
    /// O(n) work per goal per render). Threaded into the four sub-computations below via
    /// their `currentBalance:`/`input:` parameters.
    ///
    /// `currentBalance` is now (reservoir-1et) itself derived from `carryForward`, so it
    /// takes the same precomputed `carryForwardInput` rather than re-deriving its own
    /// copy — one `TodayScreenCalculator.carryForwardInput(for:calendar:)` call per
    /// render, shared by progress, pace, and simulation alike.
    private func currentBalance(input: GoalCarryForwardInput) -> Decimal {
        GoalsScreenCalculator.currentBalance(input: input, goal: goal, referenceDate: referenceDate, calendar: calendar)
    }

    private var carryForwardInput: GoalCarryForwardInput {
        TodayScreenCalculator.carryForwardInput(for: goal, calendar: calendar)
    }

    private func clampedProgress(currentBalance: Decimal) -> Double {
        NSDecimalNumber(decimal: GoalsScreenCalculator.clampedProgressFraction(currentBalance: currentBalance, goal: goal)).doubleValue
    }

    private func progressPercentText(currentBalance: Decimal) -> String {
        "\(GoalsScreenCalculator.progressPercentRounded(currentBalance: currentBalance, goal: goal))% to goal"
    }

    var body: some View {
        // Computed once here (not as accessed-per-use computed properties) so this
        // render's O(n) `goal.transactions` walk happens exactly once each, not once per
        // sub-computation that needs it.
        let carryForwardInput = carryForwardInput
        let currentBalance = currentBalance(input: carryForwardInput)

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Target: \(goal.targetAmount, format: .currency(code: "USD")) by \(dateText(goal.targetDate))")
                        .font(.subheadline)
                    Text("Started: \(dateText(goal.startDate))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                }
                .accessibilityIdentifier("goals.card.edit")
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .accessibilityIdentifier("goals.card.delete")
            }

            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: clampedProgress(currentBalance: currentBalance))
                    .accessibilityIdentifier("goals.card.progressBar")
                Text(progressPercentText(currentBalance: currentBalance))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("goals.card.progressText")
            }

            Picker("Pace view", selection: $selectedSegment) {
                ForEach(Segment.allCases) { segment in
                    Text(segment.rawValue).tag(segment)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("goals.card.segmentedControl")

            Group {
                switch selectedSegment {
                case .pace:
                    Text(paceText(input: carryForwardInput))
                case .simulation:
                    simulationContent(input: carryForwardInput)
                }
            }
            .font(.subheadline)
            .accessibilityIdentifier("goals.card.paceContent")
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("goals.card")
    }

    // MARK: - Pace segment copy

    private func paceText(input: GoalCarryForwardInput) -> String {
        switch GoalsScreenCalculator.paceStatus(input: input, targetDate: goal.targetDate, referenceDate: referenceDate, calendar: calendar) {
        case .unavailable:
            return "Pace unavailable"
        case .onPace(let targetDate):
            return "On pace to meet your goal by \(dateText(targetDate))"
        case .behindPace(let daysBehind):
            return "Behind pace — ~\(daysBehind) days behind schedule"
        }
    }

    // MARK: - Simulation segment copy

    @ViewBuilder
    private func simulationContent(input: GoalCarryForwardInput) -> some View {
        switch GoalsScreenCalculator.simulationStatus(input: input, targetDate: goal.targetDate, referenceDate: referenceDate, calendar: calendar) {
        case .unavailable:
            Text("Pace unavailable")
        case .notEnoughHistory:
            Text("Not enough spending history yet")
        case .computed(let projection):
            VStack(alignment: .leading, spacing: 4) {
                Text(simulationAmountText(projection))
                Text(simulationCompletionText(projection))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func simulationAmountText(_ projection: GoalsScreenCalculator.SimulationProjection) -> String {
        let amount = abs(projection.projectedSurplusShortfall).formatted(.currency(code: "USD"))
        let target = dateText(goal.targetDate)
        return projection.avgDailyNet >= 0
            ? "Simulation: ~\(amount) ahead of target by \(target)"
            : "Simulation: ~\(amount) behind target by \(target)"
    }

    private func simulationCompletionText(_ projection: GoalsScreenCalculator.SimulationProjection) -> String {
        switch projection.completionOutcome {
        case .onSchedule(let date):
            return "Projected to finish on schedule (\(dateText(date)))"
        case .early(let days, let date):
            return "Projected to finish ~\(days) days early (around \(dateText(date)))"
        case .late(let days, let date):
            return "Projected to finish ~\(days) days late (around \(dateText(date)))"
        }
    }

    private func dateText(_ date: Date) -> String {
        date.formatted(.dateTime.month(.wide).day())
    }
}
