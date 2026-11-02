import SwiftUI

/// Today's entry to "Spending by category" (reservoir-hnt): this month's biggest category and
/// the month's total, tapping opens the full breakdown. Hidden until the month has categorized spend (manual entries have none).
struct CategorySummaryCard: View {
    let transactions: [SpendTransaction]
    let referenceDate: Date

    var body: some View {
        let summary = CategorySpendCalculator.month(
            containing: referenceDate,
            entries: transactions.map(CategorySpendCalculator.Entry.init),
            now: referenceDate
        )
        if let top = summary.rows.first(where: { $0.category != nil && $0.amount > 0 }) {
            NavigationLink {
                CategoryBreakdownView()
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Spending by category · \(referenceDate.formatted(.dateTime.month(.wide)))")
                            .font(.caption)
                            .foregroundStyle(Color("ReservoirTextSecondary"))
                        Text("\(top.name) \(top.amount.formatted(.currency(code: "USD").precision(.fractionLength(0))))")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(Color("ReservoirTextPrimary"))
                        Text("of \(summary.total.formatted(.currency(code: "USD").precision(.fractionLength(0)))) this month")
                            .font(.caption)
                            .foregroundStyle(Color("ReservoirTextSecondary"))
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color("ReservoirTextMuted"))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .reservoirCardBackground(Color("ReservoirSurface"))
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("today.categoryCard")
        }
    }
}
