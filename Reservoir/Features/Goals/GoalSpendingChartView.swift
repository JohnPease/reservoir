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

    /// The plot's Y domain. Padded ~15% above the larger of the two series' peaks so the
    /// tallest bar/highest limit tick isn't flush against the chart's top edge.
    ///
    /// Lower bound is NOT hardcoded to 0 (code-review fix, reservoir-t5u manual-QA
    /// report): a goal that's meaningfully behind pace has a deeply negative
    /// `carryForward`, which makes `dailyLimit` (`dailyBase + carryForward`) negative —
    /// realistic any time a goal has run an overspending streak, not just a contrived
    /// edge case. A domain hardcoded to `0...upperBound` has no valid position for a
    /// negative-y `RuleMark`; Swift Charts extrapolates it far past the plot's bottom
    /// edge, which (with no `.clipped()`) bled into whatever sibling view sits below the
    /// chart. Floors at the smaller of 0 and the lowest `dailyLimit` in this window,
    /// padded the same ~15%, so a negative limit still gets a valid, visible in-bounds
    /// position instead of extrapolating out of the plot entirely.
    private var yDomain: ClosedRange<Double> {
        let maxSpend = points.map(\.variableSpend).max() ?? 0
        let maxLimit = points.map(\.dailyLimit).max() ?? 0
        let minLimit = points.map(\.dailyLimit).min() ?? 0
        let peak = Self.double(max(maxSpend, maxLimit))
        let trough = min(0, Self.double(minLimit))
        let upper = max(peak, 1) * 1.15
        let lower = trough < 0 ? trough * 1.15 : 0
        return lower...upper
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
        .chartYScale(domain: yDomain)
        .chartXAxis(showAxisLabels ? .visible : .hidden)
        .chartYAxis(showAxisLabels ? .visible : .hidden)
        // Defensive backstop (code-review fix, reservoir-t5u manual-QA report): even
        // with `yDomain` now bounding real data correctly, a mark should never be able
        // to bleed into sibling views below the chart. `.frame(height:)` alone does not
        // clip SwiftUI content to its bounds.
        .clipped()
    }

    fileprivate static func double(_ value: Decimal) -> Double {
        NSDecimalNumber(decimal: value).doubleValue
    }
}
