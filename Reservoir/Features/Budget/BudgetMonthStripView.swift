import Charts
import SwiftData
import SwiftUI

/// The Plans tab's "Month" card (reservoir-h2k): every day of a month as a bar against the
/// daily base, with the carryover line underneath, so you can see how today's limit was
/// built. Tapping a day lists its transactions. Presentation only; the figures come from
/// `BudgetMonthStripCalculator`.
///
/// The month and Week/Month choice are bindings owned by `GoalsView`, because the card is
/// rebuilt when a rotation swaps the Plans layout and its own `@State` would reset. The
/// selected day stays local to `StripBody`, so dragging across the chart never re-runs the
/// day walk done here.
struct BudgetMonthStripView: View {
    let budget: Budget
    let transactions: [SpendTransaction]
    let referenceDate: Date
    /// The month being viewed; `nil` follows the current month (so it rolls over at midnight
    /// on the 1st and can never point outside the budget's range).
    @Binding var pinnedMonth: Date?
    @Binding var isWeekly: Bool
    /// True inside the full-screen cover: bigger charts, a close button instead of expand.
    var isFullScreen = false

    @State private var isShowingFullScreen = false
    @Environment(\.dismiss) private var dismiss
    private let calendar = Calendar.current

    private func strip(for month: Date) -> BudgetMonthStripCalculator.Strip? {
        BudgetMonthStripCalculator.strip(
            budget: budget, transactions: transactions, month: month, referenceDate: referenceDate, calendar: calendar
        )
    }

    var body: some View {
        // A pinned month that no longer exists (the budget's start date moved later) falls back
        // to the current one.
        let strip = strip(for: pinnedMonth ?? referenceDate) ?? strip(for: referenceDate)
        Group {
            if let strip {
                let days = visibleDays(strip)
                let content = StripBody(
                    strip: strip,
                    days: days,
                    transactionsByDay: transactionsByDay(),
                    isWeekly: $isWeekly,
                    isFullScreen: isFullScreen,
                    isCurrentMonth: !strip.hasNext,
                    onShift: { shift($0, from: strip) },
                    onExpand: { isShowingFullScreen = true }
                )
                if isFullScreen {
                    NavigationStack {
                        ScrollView { content.padding() }
                            .background(Color("ReservoirBackground"))
                            .navigationTitle("Month")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("Done") { dismiss() }
                                        .accessibilityIdentifier("budget.strip.done")
                                }
                            }
                    }
                } else {
                    content
                }
            }
        }
        // On the stable container, not inside the `if`, so a missing strip can't pull the cover away.
        .fullScreenCover(isPresented: $isShowingFullScreen) {
            BudgetMonthStripView(
                budget: budget, transactions: transactions, referenceDate: referenceDate,
                pinnedMonth: $pinnedMonth, isWeekly: $isWeekly, isFullScreen: true
            )
        }
    }

    /// The month's days, or for Week the seven ending today (or the month's last day when looking
    /// back), reaching into the previous month early in a month so it is always seven bars.
    private func visibleDays(_ strip: BudgetMonthStripCalculator.Strip) -> [BudgetMonthStripCalculator.Day] {
        guard isWeekly else { return strip.days }
        let lastIndex = strip.days.lastIndex(where: { !$0.isFuture }) ?? strip.days.count - 1
        var days = Array(strip.days[max(0, lastIndex - 6)...lastIndex])
        if days.count < 7, strip.hasPrevious,
           let previousMonth = calendar.date(byAdding: .month, value: -1, to: strip.monthStart),
           let previous = self.strip(for: previousMonth) {
            days = Array(previous.days.suffix(7 - days.count)) + days
        }
        return days
    }

    /// Counted transactions per day, built once per render from the same filter the calculator uses.
    private func transactionsByDay() -> [Date: [SpendTransaction]] {
        Dictionary(
            grouping: BudgetCalculator.countingTransactions(transactions, for: budget, calendar: calendar)
        ) { calendar.startOfDay(for: $0.date) }
    }

    private func shift(_ delta: Int, from strip: BudgetMonthStripCalculator.Strip) {
        guard let next = calendar.date(byAdding: .month, value: delta, to: strip.monthStart) else { return }
        // Paging back to the current month goes back to following it.
        let currentStart = calendar.dateInterval(of: .month, for: referenceDate)?.start
        pinnedMonth = next >= (currentStart ?? next) ? nil : next
    }
}

/// The card's content and the one piece of state that changes while scrubbing.
private struct StripBody: View {
    let strip: BudgetMonthStripCalculator.Strip
    let days: [BudgetMonthStripCalculator.Day]
    let transactionsByDay: [Date: [SpendTransaction]]
    @Binding var isWeekly: Bool
    let isFullScreen: Bool
    let isCurrentMonth: Bool
    let onShift: (Int) -> Void
    let onExpand: () -> Void

    @State private var selectedDate: Date?
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private let calendar = Calendar.current

    /// Taller charts when there is room; a landscape phone is about 400 pt high.
    private var spendHeight: CGFloat { isFullScreen ? (verticalSizeClass == .compact ? 220 : 340) : 170 }
    private var carryHeight: CGFloat { isFullScreen ? (verticalSizeClass == .compact ? 120 : 170) : 90 }

    /// Only days that have happened can be selected; a future day has nothing to show.
    private var selected: BudgetMonthStripCalculator.Day? {
        guard let selectedDate else { return nil }
        return days.first { !$0.isFuture && calendar.isDate($0.date, inSameDayAs: selectedDate) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Picker("Range", selection: $isWeekly) {
                Text("Week").tag(true)
                Text("Month").tag(false)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("budget.strip.range")
            .onChange(of: isWeekly) { selectedDate = nil }

            Text("Daily spend against the \(BudgetSummaryCalculator.whole(days.first?.base ?? 0)) base")
                .font(.caption)
                .foregroundStyle(Color("ReservoirTextSecondary"))
            spendChart
                .frame(height: spendHeight)
                .accessibilityIdentifier("budget.strip.spend")

            Text("Carried forward")
                .font(.caption)
                .foregroundStyle(Color("ReservoirTextSecondary"))
            carryChart
                .frame(height: carryHeight)
                .accessibilityIdentifier("budget.strip.carry")

            if let selected {
                dayDetail(selected)
            } else {
                Text("Tap a day to see what it spent.")
                    .font(.footnote)
                    .foregroundStyle(Color("ReservoirTextMuted"))
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .reservoirCardBackground()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("budget.strip")
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(strip.monthStart.formatted(.dateTime.month(.wide).year()))
                    .font(.headline)
                    .foregroundStyle(Color("ReservoirTextPrimary"))
                Text(carryText)
                    .font(.subheadline)
                    .foregroundStyle(strip.carryNow < 0 ? Color("ReservoirDeficit") : Color("ReservoirTextSecondary"))
                    .accessibilityIdentifier("budget.strip.carryNow")
            }
            Spacer()
            if !isFullScreen {
                Button(action: onExpand) { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .accessibilityLabel("Show full screen")
                    .accessibilityIdentifier("budget.strip.fullScreen")
            }
            Button { selectedDate = nil; onShift(-1) } label: { Image(systemName: "chevron.left") }
                .disabled(!strip.hasPrevious)
                .accessibilityLabel("Previous month")
                .accessibilityIdentifier("budget.strip.previous")
            Button { selectedDate = nil; onShift(1) } label: { Image(systemName: "chevron.right") }
                .disabled(!strip.hasNext)
                .accessibilityLabel("Next month")
                .accessibilityIdentifier("budget.strip.next")
        }
    }

    /// "So far" while the month is running, "at month end" once it is over.
    private var carryText: String {
        let when = isCurrentMonth ? "so far" : "at month end"
        let carry = strip.carryNow
        if carry > 0 { return "\(BudgetSummaryCalculator.whole(carry)) ahead \(when)" }
        if carry < 0 { return "\(BudgetSummaryCalculator.whole(-carry)) behind \(when)" }
        return "Right on the base \(when)"
    }

    private var spendChart: some View {
        Chart {
            ForEach(days) { day in
                if !day.isFuture {
                    BarMark(x: .value("Day", day.date, unit: .day), y: .value("Spent", day.spent.doubleValue))
                        .foregroundStyle(day.isOverBase ? Color("ReservoirDeficit") : Color("ReservoirAccent"))
                        .opacity(day.isToday ? 0.6 : 1)
                }
            }
            if let base = days.first?.base {
                RuleMark(y: .value("Base", base.doubleValue))
                    .foregroundStyle(Color("ReservoirTextSecondary"))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
            if let selected {
                RuleMark(x: .value("Selected", selected.date, unit: .day))
                    .foregroundStyle(Color("ReservoirTextPrimary").opacity(0.4))
            }
        }
        .chartXSelection(value: $selectedDate)
        .chartXScale(domain: xDomain)
        .chartXAxis { dayAxis }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(Color("ReservoirTextMuted").opacity(0.3))
                AxisValueLabel { if let v = value.as(Double.self) { Text("$\(Int(v))") } }
            }
        }
    }

    private var carryChart: some View {
        // Today's own spend is not banked yet, so the line stops at yesterday.
        let past = days.filter { !$0.isFuture && !$0.isToday }
        return Chart {
            RuleMark(y: .value("Zero", 0))
                .foregroundStyle(Color("ReservoirTextMuted").opacity(0.5))
            ForEach(past) { day in
                LineMark(x: .value("Day", day.date, unit: .day), y: .value("Carried", day.carryOut.doubleValue))
                    .foregroundStyle(Color("ReservoirAccent"))
                    .interpolationMethod(.monotone)
                PointMark(x: .value("Day", day.date, unit: .day), y: .value("Carried", day.carryOut.doubleValue))
                    .foregroundStyle(Color("ReservoirAccent"))
                    .symbolSize(past.count > 14 ? 14 : 30)
            }
        }
        .chartXScale(domain: xDomain)
        .chartXAxis { dayAxis }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisValueLabel { if let v = value.as(Double.self) { Text("$\(Int(v))") } }
            }
        }
    }

    /// The full span of the visible days, so a month early on keeps its shape and the
    /// future days show as empty room rather than the chart stretching to fit what exists.
    private var xDomain: ClosedRange<Date> {
        let first = days.first?.date ?? .now
        let last = days.last?.date ?? first
        return first...(calendar.date(byAdding: .day, value: 1, to: last) ?? last)
    }

    private var dayAxis: some AxisContent {
        AxisMarks(values: .stride(by: .day, count: days.count > 14 ? 5 : 1)) { _ in
            AxisValueLabel(format: .dateTime.day())
        }
    }

    private func dayDetail(_ day: BudgetMonthStripCalculator.Day) -> some View {
        let rows = (transactionsByDay[day.date] ?? []).sorted { $0.date > $1.date }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(day.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(day.isOver ? "Over by \(BudgetSummaryCalculator.whole(day.spent - day.limit))" : "Limit \(BudgetSummaryCalculator.whole(day.limit))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(day.isOver ? Color("ReservoirDeficit") : Color("ReservoirTextSecondary"))
            }
            Text("Spent \(BudgetSummaryCalculator.whole(day.spent)) · base \(BudgetSummaryCalculator.whole(day.base)) · carried in \(BudgetSummaryCalculator.whole(day.carryIn))")
                .font(.caption)
                .foregroundStyle(Color("ReservoirTextSecondary"))
            ForEach(rows, id: \.persistentModelID) { transaction in
                HStack {
                    Text(transaction.merchantName)
                    Spacer()
                    Text(transaction.amount, format: .currency(code: "USD"))
                }
                .font(.subheadline)
                .foregroundStyle(Color("ReservoirTextPrimary"))
            }
        }
        .padding(.top, 4)
        .accessibilityIdentifier("budget.strip.dayDetail")
    }
}

private extension Decimal {
    var doubleValue: Double { NSDecimalNumber(decimal: self).doubleValue }
}
