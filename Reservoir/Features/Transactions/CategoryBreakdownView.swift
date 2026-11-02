import SwiftData
import SwiftUI

extension CategorySpendCalculator.Entry {
    init(_ transaction: SpendTransaction) {
        self.init(date: transaction.date, amount: transaction.amount, category: transaction.category)
    }
}

/// Read-only "Spending by category" screen (reservoir-27a, reservoir-hnt): one month at a
/// time, using Plaid's categories as imported, each row compared with the month before.
/// Presentation only; the grouping is `CategorySpendCalculator`.
struct CategoryBreakdownView: View {
    @Query private var transactions: [SpendTransaction]
    @Environment(TodayClock.self) private var todayClock

    @State private var monthOffset = 0

    private let calendar = Calendar.current

    var body: some View {
        let month = displayedMonth
        let entries = transactions.map(CategorySpendCalculator.Entry.init)
        let summary = CategorySpendCalculator.month(
            containing: month, entries: entries, now: todayClock.referenceDate, calendar: calendar
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
                        NavigationLink {
                            CategoryTrendView(category: row.category, month: month)
                        } label: {
                            CategoryRowView(row: row, total: summary.total)
                        }
                    }
                } footer: {
                    Text(footer(for: summary))
                }
            }
        }
        .navigationTitle("Spending by category")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var displayedMonth: Date {
        calendar.date(byAdding: .month, value: monthOffset, to: todayClock.referenceDate) ?? todayClock.referenceDate
    }

    private func footer(for summary: CategorySpendCalculator.Month) -> String {
        var text = "Total \(summary.total.formatted(.currency(code: "USD")))."
        text += summary.comparesPartialMonth
            ? " Changes compare with the same days of last month."
            : " Changes compare with the month before."
        return text + " Categories come from Plaid and can be wrong."
    }
}

private struct CategoryRowView: View {
    let row: CategorySpendCalculator.Row
    let total: Decimal

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(row.name)
                Spacer()
                Text(row.amount.formatted(.currency(code: "USD")))
                    .monospacedDigit()
            }
            ProgressView(value: share)
            HStack {
                Text("\(row.count) \(row.count == 1 ? "charge" : "charges")")
                Spacer()
                changeLabel
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var share: Double {
        guard total > 0 else { return 0 }
        return NSDecimalNumber(decimal: row.amount / total).doubleValue
    }

    @ViewBuilder private var changeLabel: some View {
        let change = row.change
        if change == 0 {
            Text("no change")
        } else {
            let amount = abs(change).formatted(.currency(code: "USD").precision(.fractionLength(0)))
            Label(
                change > 0 ? "up \(amount)" : "down \(amount)",
                systemImage: change > 0 ? "arrow.up" : "arrow.down"
            )
            .foregroundStyle(change > 0 ? Color("ReservoirDeficit") : Color("ReservoirTextSecondary"))
        }
    }
}
