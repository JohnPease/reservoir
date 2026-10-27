import SwiftData
import SwiftUI

/// "Past months" screen (reservoir-62p): presentation only. Everything shown comes from
/// `BudgetMonthReviewCalculator.screen`, computed when the sheet is opened.
struct BudgetMonthReviewView: View {
    let budget: Budget
    let transactions: [SpendTransaction]
    let isAccountBackfillComplete: Bool
    let referenceDate: Date

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let calendar = Calendar.current
        let screen = BudgetMonthReviewCalculator.screen(
            budget: budget,
            transactions: transactions,
            isAccountBackfillComplete: isAccountBackfillComplete,
            referenceDate: referenceDate,
            calendar: calendar
        )
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    switch screen {
                    case .status(let state):
                        message(state.message ?? "", identifier: "budget.pastMonths.status")
                    case .empty:
                        message(BudgetMonthReviewCalculator.emptyMessage, identifier: "budget.pastMonths.empty")
                    case .months(let months):
                        ForEach(months, id: \.monthStart) { review in
                            BudgetMonthReviewRowView(
                                review: review,
                                carriesAcrossMonths: budget.carriesAcrossMonths,
                                calendar: calendar
                            )
                        }
                    }
                }
                .padding()
            }
            .background(Color("ReservoirBackground"))
            .navigationTitle("Past months")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("budget.pastMonths.done")
                }
            }
        }
        .accessibilityIdentifier("budget.pastMonths.sheet")
    }

    private func message(_ text: String, identifier: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(Color("ReservoirTextSecondary"))
            .frame(maxWidth: .infinity)
            .padding()
            .accessibilityIdentifier(identifier)
    }
}

/// One completed month's card.
struct BudgetMonthReviewRowView: View {
    let review: BudgetMonthReviewCalculator.MonthReview
    let carriesAcrossMonths: Bool
    let calendar: Calendar

    private var title: String {
        let month = review.monthStart.formatted(.dateTime.month(.wide).year())
        guard review.isPartialStart else { return month }
        return "\(month) (from \(review.windowStart.formatted(.dateTime.month(.abbreviated).day())))"
    }

    private var carryText: String {
        guard carriesAcrossMonths else { return "Fresh start" }
        let carry = review.endingCarry
        let sign = carry < 0 ? "-" : (carry > 0 ? "+" : "")
        return "Ended with \(sign)\(BudgetSummaryCalculator.whole(abs(carry))) carried"
    }

    private var id: String {
        let c = calendar.dateComponents([.year, .month], from: review.monthStart)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Color("ReservoirTextPrimary"))
            line("Budgeted", BudgetSummaryCalculator.whole(review.budgeted))
            line("Spent", BudgetSummaryCalculator.whole(review.spent))
            HStack {
                Text(review.deltaText)
                    .foregroundStyle(review.verdict == .over ? Color("ReservoirDeficit") : Color("ReservoirTextPrimary"))
                    .accessibilityIdentifier("budget.pastMonths.delta.\(id)")
                Spacer()
                Text(review.daysOverText)
                    .foregroundStyle(Color("ReservoirTextSecondary"))
                    .accessibilityIdentifier("budget.pastMonths.daysOver.\(id)")
            }
            .font(.subheadline)
            Text(carryText)
                .font(.caption)
                .foregroundStyle(Color("ReservoirTextSecondary"))
                .accessibilityIdentifier("budget.pastMonths.carry.\(id)")
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .reservoirCardBackground()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("budget.pastMonths.row.\(id)")
    }

    private func line(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(Color("ReservoirTextSecondary"))
            Spacer()
            Text(value).foregroundStyle(Color("ReservoirTextPrimary"))
        }
        .font(.subheadline)
    }
}
