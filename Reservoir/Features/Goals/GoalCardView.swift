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

    private var clampedProgress: Double {
        NSDecimalNumber(decimal: GoalsScreenCalculator.clampedProgressFraction(for: goal)).doubleValue
    }

    private var progressPercentText: String {
        let percent = GoalsScreenCalculator.progressFraction(for: goal) * 100
        let rounded = NSDecimalNumber(decimal: percent).intValue
        return "\(rounded)% to goal"
    }

    var body: some View {
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
                ProgressView(value: clampedProgress)
                    .accessibilityIdentifier("goals.card.progressBar")
                Text(progressPercentText)
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
                    Text(paceText)
                case .simulation:
                    simulationContent
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

    private var paceText: String {
        switch GoalsScreenCalculator.paceStatus(for: goal, referenceDate: referenceDate, calendar: calendar) {
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
    private var simulationContent: some View {
        switch GoalsScreenCalculator.simulationStatus(for: goal, referenceDate: referenceDate, calendar: calendar) {
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
