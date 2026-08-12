import SwiftUI
import Charts

/// The tap-to-expand modal for one goal's spend chart (reservoir-t5u task 2), presented
/// from `ActiveGoalCardView`'s compact chart as a `.sheet` with `.presentationDetents(
/// [.large])`. Standard swipe-down-to-dismiss — deliberately no custom close button (see
/// the bead's acceptance criteria).
///
/// Reuses `GoalSpendingChartView` (task 3's shared helper) for the actual marks, and
/// `GoalsScreenCalculator.spendChartWindow`/`chartWindowCount`/`chartWindowEnd` for all of
/// the windowing math — this view only owns paging state, the header copy, and the
/// tap-to-select annotation.
struct SpendingChartDetailView: View {
    let goal: SavingsGoal
    let referenceDate: Date
    let calendar: Calendar

    /// Page 0 = the current (most recent) window ending on `referenceDate`; each
    /// increment steps one window further back into the goal's history. Bounded at
    /// `windowCount - 1` — the earliest page, whose window naturally stops at the goal's
    /// own start date (see `GoalsScreenCalculator.chartWindowEnd`'s doc comment).
    @State private var page = 0

    /// The bar the user tapped, wired to `Chart`'s standard `chartXSelection` (iOS 17
    /// Swift Charts API) via `GoalSpendingChartView`. Resets on every page change so a
    /// selection from a previous window can't linger and mis-annotate the new one.
    @State private var selectedDay: Date?

    private var effectiveStartDate: Date {
        TodayScreenCalculator.carryForwardInput(for: goal, calendar: calendar).effectiveStartDate
    }

    private var windowCount: Int {
        GoalsScreenCalculator.chartWindowCount(effectiveStartDate: effectiveStartDate, referenceDate: referenceDate, calendar: calendar)
    }

    private func windowEnd(forPage page: Int) -> Date {
        GoalsScreenCalculator.chartWindowEnd(page: page, referenceDate: referenceDate, calendar: calendar)
    }

    private func points(forPage page: Int) -> [GoalsScreenCalculator.DailySpendPoint] {
        GoalsScreenCalculator.spendChartWindow(for: goal, windowEnd: windowEnd(forPage: page), calendar: calendar)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(goal.displayName)
                    .font(.headline)
                    .foregroundStyle(Color("ReservoirTextPrimary"))
                    .accessibilityIdentifier("goals.chartDetail.goalName")

                Text(dateRangeText(forPage: page))
                    .font(.subheadline)
                    .foregroundStyle(Color("ReservoirTextSecondary"))
                    .accessibilityIdentifier("goals.chartDetail.dateRange")

                pager
                    .frame(height: 280)

                if let selectedDay, let point = points(forPage: page).first(where: { $0.day == selectedDay }) {
                    selectionAnnotation(point)
                }

                Spacer()
            }
            .padding()
            .background(Color("ReservoirBackground"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.large])
        .accessibilityIdentifier("goals.chartDetailSheet")
    }

    /// `TabView(.page)` — Swift Charts' own tap/drag handling (`chartXSelection`) and
    /// `TabView(.page)`'s swipe gesture did not conflict in a brief spike: `TabView`
    /// claims horizontal drags for paging while `Chart`'s tap-to-select is a distinct
    /// gesture (a tap, not a drag), so both coexist without a hand-rolled
    /// `DragGesture`/`.simultaneousGesture` pager. Kept as the simpler, more "standard
    /// SwiftUI" option, per the bead's own stated preference when the two don't conflict.
    private var pager: some View {
        TabView(selection: $page) {
            ForEach(0..<windowCount, id: \.self) { pageIndex in
                GoalSpendingChartView(
                    points: points(forPage: pageIndex),
                    showAxisLabels: true,
                    selection: $selectedDay
                )
                .padding(.horizontal, 4)
                .tag(pageIndex)
                .accessibilityIdentifier("goals.chartDetail.chart.\(pageIndex)")
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .automatic))
        .onChange(of: page) { _, _ in
            selectedDay = nil
        }
    }

    private func selectionAnnotation(_ point: GoalsScreenCalculator.DailySpendPoint) -> some View {
        HStack {
            Text(point.day.formatted(.dateTime.month(.wide).day().year()))
                .foregroundStyle(Color("ReservoirTextPrimary"))
            Spacer()
            Text(point.variableSpend.formatted(.currency(code: "USD")))
                .foregroundStyle(point.variableSpend > point.dailyLimit ? Color("ReservoirDeficit") : Color("ReservoirTextPrimary"))
        }
        .font(.subheadline)
        .padding(10)
        .background(Color("ReservoirSurface"), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("goals.chartDetail.selectionAnnotation")
    }

    /// "Jul 12 – Aug 10" — the current page's window start/end, matching the bead's exact
    /// example format (no year unless the window spans a year boundary would be a nicer
    /// touch, but the bead's example omits it and this app's other date copy — e.g.
    /// `ActiveGoalCardView.dateText`/`SavingsGoal.displayName` — is consistently
    /// year-omitting too).
    private func dateRangeText(forPage page: Int) -> String {
        let pagePoints = points(forPage: page)
        guard let first = pagePoints.first?.day, let last = pagePoints.last?.day else {
            return ""
        }
        let formatter: Date.FormatStyle = .dateTime.month(.abbreviated).day()
        return "\(first.formatted(formatter)) – \(last.formatted(formatter))"
    }
}
