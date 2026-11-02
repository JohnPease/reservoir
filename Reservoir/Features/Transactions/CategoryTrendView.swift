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

    private let calendar = Calendar.current
    private static let monthCount = 6

    var body: some View {
        let history = CategorySpendCalculator.history(
            for: category,
            months: Self.monthCount,
            endingAt: month,
            entries: transactions.map(CategorySpendCalculator.Entry.init),
            calendar: calendar
        )
        let earlier = history.dropLast()
        let average = earlier.isEmpty ? 0 : earlier.reduce(Decimal(0)) { $0 + $1.amount } / Decimal(earlier.count)
        List {
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
