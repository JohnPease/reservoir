import SwiftData
import SwiftUI

/// Read-only "Spending by category" screen (reservoir-27a): one month at a time, using
/// Plaid's categories as imported. Presentation only; the grouping is `CategorySpendCalculator`.
struct CategoryBreakdownView: View {
    @Query private var transactions: [SpendTransaction]
    @Environment(TodayClock.self) private var todayClock

    @State private var monthOffset = 0

    private let calendar = Calendar.current

    var body: some View {
        let month = displayedMonth
        let summary = CategorySpendCalculator.month(
            containing: month,
            entries: transactions.map { .init(date: $0.date, amount: $0.amount, category: $0.category) },
            calendar: calendar
        )
        List {
            Section {
                HStack {
                    Button { monthOffset -= 1 } label: { Image(systemName: "chevron.left") }
                        .accessibilityLabel("Previous month")
                    Spacer()
                    Text(month.formatted(.dateTime.month(.wide).year()))
                        .font(.headline)
                        .accessibilityIdentifier("categories.month")
                    Spacer()
                    Button { monthOffset += 1 } label: { Image(systemName: "chevron.right") }
                        .disabled(monthOffset >= 0)
                        .accessibilityLabel("Next month")
                }
                .buttonStyle(.borderless)
            }
            if summary.rows.isEmpty {
                Section { Text("No spending this month").foregroundStyle(.secondary) }
            } else {
                Section {
                    ForEach(summary.rows, id: \.category) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(row.name)
                                Spacer()
                                Text(row.amount.formatted(.currency(code: "USD")))
                                    .monospacedDigit()
                            }
                            ProgressView(value: share(row.amount, of: summary.total))
                            Text("\(row.count) \(row.count == 1 ? "charge" : "charges")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                } footer: {
                    Text("Total \(summary.total.formatted(.currency(code: "USD"))). Categories come from Plaid and can be wrong.")
                }
            }
        }
        .navigationTitle("Spending by category")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var displayedMonth: Date {
        calendar.date(byAdding: .month, value: monthOffset, to: todayClock.referenceDate) ?? todayClock.referenceDate
    }

    private func share(_ amount: Decimal, of total: Decimal) -> Double {
        guard total > 0 else { return 0 }
        return NSDecimalNumber(decimal: amount / total).doubleValue
    }
}
