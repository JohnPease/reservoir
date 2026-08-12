import SwiftUI
import Charts

/// Shared BarMark + per-day RuleMark chart body for one goal's windowed variable-spend
/// history — used by both the compact preview on `ActiveGoalCardView` and the enlarged
/// chart in `SpendingChartDetailView`'s modal, parameterized by size/interactivity so
/// neither duplicates the BarMark/RuleMark/coloring logic (STANDARDS.md §3 — reservoir-t5u
/// task 3 explicitly calls this out as a required, checked-in-review factoring).
///
/// All of the underlying numbers (`variableSpend`, `dailyLimit` per day) come from
/// `GoalsScreenCalculator.spendChartWindow` — this view only renders them; no calculator
/// logic lives here.
struct GoalSpendingChartView: View {
    let points: [GoalsScreenCalculator.DailySpendPoint]

    /// The compact card has no room (and no real value) for axis labels; the enlarged
    /// modal chart shows both a date axis and a currency axis.
    var showAxisLabels: Bool = false

    /// Wired to `.chartXSelection` only by the modal (task 2's tap-to-annotate) — the
    /// compact card is a static, tap-to-open preview, not independently interactive, so
    /// it passes `nil`.
    var selection: Binding<Date?>? = nil

    /// Below this many days of history, a chart would be misleadingly sparse — render the
    /// "not enough data" state instead. 3, per the bead's acceptance criteria. Exposed as
    /// a parameter (not hardcoded in the body) so both call sites and tests can reason
    /// about the exact threshold in one place.
    var minimumPointCount: Int = 3

    var body: some View {
        if points.count < minimumPointCount {
            notEnoughDataView
        } else {
            chart
        }
    }

    // MARK: - Not enough data

    private var notEnoughDataView: some View {
        VStack(spacing: 4) {
            Image(systemName: "chart.bar")
                .foregroundStyle(Color("ReservoirTextMuted"))
            Text("Not enough spending history yet")
                .font(.caption)
                .foregroundStyle(Color("ReservoirTextSecondary"))
        }
        .frame(maxWidth: .infinity, minHeight: 80)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("goals.chart.notEnoughData")
    }

    // MARK: - Chart

    /// The plot's Y domain, padded ~15% above the larger of the two series' peaks so the
    /// tallest bar/highest limit tick isn't flush against the chart's top edge.
    private var yDomainUpperBound: Double {
        let maxSpend = points.map(\.variableSpend).max() ?? 0
        let maxLimit = points.map(\.dailyLimit).max() ?? 0
        let peak = Self.double(max(maxSpend, maxLimit))
        return max(peak, 1) * 1.15
    }

    @ViewBuilder
    private var chart: some View {
        if let selection {
            baseChart.chartXSelection(value: selection)
        } else {
            baseChart
        }
    }

    private var baseChart: some View {
        Chart {
            ForEach(points) { point in
                BarMark(
                    x: .value("Day", point.day, unit: .day),
                    y: .value("Spend", Self.double(point.variableSpend))
                )
                .foregroundStyle(point.variableSpend > point.dailyLimit ? Color("ReservoirDeficit") : Color("ReservoirTextMuted"))

                // A per-day horizontal tick at that day's own limit — `xStart`/`xEnd`
                // both bucketed to the same `unit: .day` value span exactly that day's
                // bar width, the same way `BarMark`'s single `.day`-unit `x` does.
                RuleMark(
                    xStart: .value("Day", point.day, unit: .day),
                    xEnd: .value("Day", point.day, unit: .day),
                    y: .value("Limit", Self.double(point.dailyLimit))
                )
                .foregroundStyle(Color("ReservoirTextSecondary"))
                .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
        }
        .chartYScale(domain: 0...yDomainUpperBound)
        .chartXAxis(showAxisLabels ? .visible : .hidden)
        .chartYAxis(showAxisLabels ? .visible : .hidden)
    }

    fileprivate static func double(_ value: Decimal) -> Double {
        NSDecimalNumber(decimal: value).doubleValue
    }
}
