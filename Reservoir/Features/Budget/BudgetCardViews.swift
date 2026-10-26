import SwiftUI

/// Today's monthly-budget hero (reservoir-j8t): the same hero + stats as the savings
/// card when the budget is active, or a status card ("Syncing account data..." /
/// "Choose accounts") when it can't show numbers yet. Which state applies is decided by
/// `BudgetCalculator.cardState`, not here.
struct BudgetHeroCardView: View {
    static let title = "Monthly budget"

    let state: BudgetCalculator.CardState
    let summary: TodayScreenCalculator.Summary?
    var insights: BudgetSummaryCalculator.BudgetInsights?
    var onChooseAccounts: () -> Void = {}

    var body: some View {
        if state == .active, let summary {
            VStack(spacing: 24) {
                HeroSection(summary: summary, title: Self.title, identifiers: .budget)
                TwoStatRow(summary: summary, identifier: HeroIdentifiers.budget.stats)
                if let insights {
                    BudgetProgressSentenceView(sentence: insights.sentence)
                }
            }
        } else {
            BudgetStatusView(state: state, onChooseAccounts: onChooseAccounts)
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color("ReservoirSurface"), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(HeroIdentifiers.budget.container)
        }
    }
}

/// Title + the non-numeric message for a budget that isn't `.active`.
struct BudgetStatusView: View {
    let state: BudgetCalculator.CardState
    var onChooseAccounts: () -> Void = {}

    var body: some View {
        VStack(spacing: 6) {
            Text(BudgetHeroCardView.title)
                .font(.headline)
                .foregroundStyle(Color("ReservoirTextPrimary"))
            if let message = state.message {
                if state == .chooseAccounts {
                    Button(message, action: onChooseAccounts)
                        .font(.subheadline)
                        .accessibilityIdentifier("budget.chooseAccounts")
                } else {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(Color("ReservoirTextSecondary"))
                        .accessibilityIdentifier("budget.syncing")
                }
            }
        }
    }
}

/// The Plans tab's monthly-budget card, with Edit/Delete like `ActiveGoalCardView`.
struct BudgetCardView: View {
    let budget: Budget
    let state: BudgetCalculator.CardState
    let summary: TodayScreenCalculator.Summary?
    var insights: BudgetSummaryCalculator.BudgetInsights?
    let onEdit: () -> Void
    let onDelete: () -> Void

    private var detailLine: String {
        let count = budget.selectedAccountIDs.count
        let accounts = "\(count) \(count == 1 ? "account" : "accounts")"
        let mode = budget.carriesAcrossMonths ? "Carry over" : "Start fresh"
        let since = budget.startDate.formatted(.dateTime.month(.abbreviated).day().year())
        return "\(mode) · \(accounts) · Since \(since)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(budget.monthlyAmount.formatted(.currency(code: "USD"))) / month")
                        .font(.subheadline)
                        .foregroundStyle(Color("ReservoirTextPrimary"))
                    Text(detailLine)
                        .font(.caption)
                        .foregroundStyle(Color("ReservoirTextSecondary"))
                }
                Spacer()
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .foregroundStyle(Color("ReservoirTextSecondary"))
                }
                .accessibilityIdentifier("budget.card.edit")
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .accessibilityIdentifier("budget.card.delete")
            }

            if let message = state.message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(Color("ReservoirTextSecondary"))
                    .accessibilityIdentifier("budget.card.status")
            } else if let summary {
                Text("\(summary.remaining.formatted(.currency(code: "USD"))) left today of \(summary.limit.formatted(.currency(code: "USD")))")
                    .font(.subheadline)
                    .foregroundStyle(summary.remaining < 0 ? Color("ReservoirDeficit") : Color("ReservoirTextPrimary"))
                    .accessibilityIdentifier("budget.card.today")
            }

            if let insights {
                BudgetProgressSentenceView(sentence: insights.sentence)
                if let projection = insights.projection {
                    Text(projection.text)
                        .font(.subheadline)
                        .foregroundStyle(Color("ReservoirTextSecondary"))
                        .accessibilityIdentifier("budget.projection")
                }
                if let breakdown = insights.breakdown {
                    BudgetBreakdownView(breakdown: breakdown)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color("ReservoirSurface"), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("budget.card")
    }
}

/// The quiet "no budget yet" row on the Plans tab.
struct BudgetSetRowView: View {
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Set a monthly budget")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color("ReservoirTextPrimary"))
                    Text("Track what you spend each month.")
                        .font(.caption)
                        .foregroundStyle(Color("ReservoirTextSecondary"))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(Color("ReservoirTextMuted"))
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color("ReservoirSurface"), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("budget.setRow")
    }
}

/// The pace sentence; only the over-pace / over-budget phrase uses `ReservoirDeficit`.
/// Wording and the three-part split come from `BudgetSummaryCalculator`.
struct BudgetProgressSentenceView: View {
    let sentence: BudgetSummaryCalculator.ProgressSentence

    var body: some View {
        Group {
            if let deficit = sentence.deficitPhrase {
                Text(sentence.lead) + Text(deficit).foregroundColor(Color("ReservoirDeficit")) + Text(sentence.tail)
            } else {
                Text(sentence.text)
            }
        }
        .font(.subheadline)
        .foregroundStyle(Color("ReservoirTextSecondary"))
        .multilineTextAlignment(.leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(sentence.text)
        .accessibilityIdentifier("budget.progressSentence")
    }
}

/// Plain per-account list of this month's counted spend (no chart, no tap-through).
struct BudgetBreakdownView: View {
    let breakdown: BudgetSummaryCalculator.Breakdown

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(breakdown.rows, id: \.accountID) { row in
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(row.title)
                            .foregroundStyle(Color("ReservoirTextPrimary"))
                        Spacer()
                        Text(row.spent, format: .currency(code: "USD"))
                            .foregroundStyle(Color("ReservoirTextPrimary"))
                    }
                    if row.needsRelink {
                        Text("Needs relink")
                            .font(.caption)
                            .foregroundStyle(Color("ReservoirTextMuted"))
                    }
                }
                .font(.subheadline)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("budget.breakdown.row.\(row.accountID)")
            }
            if let caption = breakdown.unlinkedCaption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(Color("ReservoirTextMuted"))
            }
        }
        .padding(.top, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("budget.breakdown")
    }
}
