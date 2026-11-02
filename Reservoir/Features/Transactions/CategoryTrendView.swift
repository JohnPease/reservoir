import Charts
import SwiftData
import SwiftUI

/// One category's last six months as bars (reservoir-hnt). Presentation only; the numbers
/// come from `CategorySpendCalculator.history`.
struct CategoryTrendView: View {
    let category: String?
    /// The month the user was looking at; the chart ends here.
    let month: Date

    @Query private var transactions: [SpendTransaction]
    @Environment(TodayClock.self) private var todayClock

    private let calendar = Calendar.current
    private static let monthCount = 6

    var body: some View {
        let entries = transactions.map(CategorySpendCalculator.Entry.init)
        let history = CategorySpendCalculator.history(
            for: category,
            months: Self.monthCount,
            endingAt: month,
            entries: entries,
            calendar: calendar
        )
        let callout = CategorySpendCalculator.callouts(
            month: month, entries: entries, now: todayClock.referenceDate, calendar: calendar
        ).first { $0.category == category }
        let detail = CategorySpendCalculator.detail(
            for: category, month: month, entries: entries, now: todayClock.referenceDate, calendar: calendar
        )
        let earlier = history.dropLast()
        let average = earlier.isEmpty ? 0 : earlier.reduce(Decimal(0)) { $0 + $1.amount } / Decimal(earlier.count)
        List {
            if let callout {
                Section { CalloutRowView(callout: callout) }
            }
            Section {
                Chart(history, id: \.monthStart) { item in
                    BarMark(
                        x: .value("Month", item.monthStart, unit: .month),
                        y: .value("Spent", NSDecimalNumber(decimal: item.amount).doubleValue)
                    )
                    .foregroundStyle(item.monthStart == history.last?.monthStart ? Color("ReservoirAccent") : Color("ReservoirTextMuted"))
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .month)) { _ in
                        AxisValueLabel(format: .dateTime.month(.abbreviated))
                    }
                }
                .frame(height: 200)
                .accessibilityIdentifier("categories.trendChart")
            } footer: {
                if !earlier.isEmpty {
                    Text("Average of the earlier \(earlier.count) months: \(average.formatted(.currency(code: "USD").precision(.fractionLength(0)))).")
                }
            }
            Section {
                NavigationLink {
                    CategoryChargesView(title: CategorySpendCalculator.displayName(for: category), category: category, month: month)
                } label: {
                    Text("See \(month.formatted(.dateTime.month(.wide))) charges")
                }
                .accessibilityIdentifier("categories.seeCharges")
            }
            if detail.count > 1 || detail.first?.detailed != nil {
                Section("Within \(CategorySpendCalculator.displayName(for: category))") {
                    ForEach(detail, id: \.detailed) { row in
                        NavigationLink {
                            CategoryChargesView(title: row.name, category: category, detailed: .some(row.detailed), month: month)
                        } label: {
                            DetailRowView(row: row)
                        }
                    }
                }
                .accessibilityIdentifier("categories.detail")
            }
            Section {
                ForEach(history.reversed(), id: \.monthStart) { item in
                    HStack {
                        Text(item.monthStart.formatted(.dateTime.month(.wide).year()))
                        Spacer()
                        Text(item.amount.formatted(.currency(code: "USD")))
                            .monospacedDigit()
                    }
                }
            }
        }
        .navigationTitle(CategorySpendCalculator.displayName(for: category))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct DetailRowView: View {
    let row: CategorySpendCalculator.DetailRow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(row.name)
                Spacer()
                Text(row.amount.formatted(.currency(code: "USD")))
                    .monospacedDigit()
            }
            HStack {
                Text("\(row.count) \(row.count == 1 ? "charge" : "charges")")
                Spacer()
                if row.change != 0 {
                    let amount = abs(row.change).formatted(.currency(code: "USD").precision(.fractionLength(0)))
                    Text(row.change > 0 ? "up \(amount)" : "down \(amount)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
