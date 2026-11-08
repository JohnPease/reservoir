import Charts
import SwiftData
import SwiftUI

/// The Plans tab's "Month" card (reservoir-h2k): every day of a month as a bar against the
/// daily base, with the carryover line underneath, so you can see how today's limit was
/// built. Tapping a day lists its transactions. Presentation only; the figures come from
/// `BudgetMonthStripCalculator`.
struct BudgetMonthStripView: View {
    let budget: Budget
    let transactions: [SpendTransaction]
    let referenceDate: Date

    private enum Range: String, CaseIterable, Identifiable {
        case week = "Week", month = "Month"
        var id: String { rawValue }
    }

    @State private var month: Date
    @State private var range: Range = .month
    @State private var selectedDate: Date?
    private let calendar = Calendar.current

    init(budget: Budget, transactions: [SpendTransaction], referenceDate: Date) {
        self.budget = budget
        self.transactions = transactions
        self.referenceDate = referenceDate
        _month = State(initialValue: referenceDate)
    }

    var body: some View {
        if let strip = BudgetMonthStripCalculator.strip(
            budget: budget, transactions: transactions, month: month, referenceDate: referenceDate, calendar: calendar
        ) {
            content(strip)
        }
    }

    private func visibleDays(_ strip: BudgetMonthStripCalculator.Strip) -> [BudgetMonthStripCalculator.Day] {
        guard range == .week else { return strip.days }
        // The seven days ending today (or the month's last day when looking back).
        let lastIndex = strip.days.lastIndex(where: { !$0.isFuture }) ?? strip.days.count - 1
        return Array(strip.days[max(0, lastIndex - 6)...lastIndex])
    }

    private func content(_ strip: BudgetMonthStripCalculator.Strip) -> some View {
        let days = visibleDays(strip)
        let selected = days.first { calendar.isDate($0.date, inSameDayAs: selectedDate ?? .distantPast) }
        return VStack(alignment: .leading, spacing: 12) {
            header(strip)
            Picker("Range", selection: $range) {
                ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("budget.strip.range")

            Text("Daily spend against the \(BudgetSummaryCalculator.whole(days.first?.base ?? 0)) base")
                .font(.caption)
                .foregroundStyle(Color("ReservoirTextSecondary"))
            spendChart(days, selected: selected)
                .frame(height: 170)
                .accessibilityIdentifier("budget.strip.spend")

            Text("Carried forward")
                .font(.caption)
                .foregroundStyle(Color("ReservoirTextSecondary"))
            carryChart(days)
                .frame(height: 90)
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

    private func header(_ strip: BudgetMonthStripCalculator.Strip) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(strip.monthStart.formatted(.dateTime.month(.wide).year()))
                    .font(.headline)
                    .foregroundStyle(Color("ReservoirTextPrimary"))
                Text(carryText(strip.carryNow))
                    .font(.subheadline)
                    .foregroundStyle(strip.carryNow < 0 ? Color("ReservoirDeficit") : Color("ReservoirTextSecondary"))
                    .accessibilityIdentifier("budget.strip.carryNow")
            }
            Spacer()
            Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                .disabled(!strip.hasPrevious)
                .accessibilityLabel("Previous month")
                .accessibilityIdentifier("budget.strip.previous")
            Button { shift(1) } label: { Image(systemName: "chevron.right") }
                .disabled(!strip.hasNext)
                .accessibilityLabel("Next month")
                .accessibilityIdentifier("budget.strip.next")
        }
    }

    private func carryText(_ carry: Decimal) -> String {
        if carry > 0 { return "\(BudgetSummaryCalculator.whole(carry)) ahead so far" }
        if carry < 0 { return "\(BudgetSummaryCalculator.whole(-carry)) behind so far" }
        return "Right on the base so far"
    }

    private func shift(_ delta: Int) {
        if let next = calendar.date(byAdding: .month, value: delta, to: month) {
            month = next
            selectedDate = nil
        }
    }

    private func spendChart(_ days: [BudgetMonthStripCalculator.Day], selected: BudgetMonthStripCalculator.Day?) -> some View {
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
        .chartXScale(domain: xDomain(days))
        .chartXAxis { dayAxis(days) }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(Color("ReservoirTextMuted").opacity(0.3))
                AxisValueLabel { if let v = value.as(Double.self) { Text("$\(Int(v))") } }
            }
        }
    }

    private func carryChart(_ days: [BudgetMonthStripCalculator.Day]) -> some View {
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
        .chartXScale(domain: xDomain(days))
        .chartXAxis { dayAxis(days) }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisValueLabel { if let v = value.as(Double.self) { Text("$\(Int(v))") } }
            }
        }
    }

    /// The full span of the visible days, so a month early on keeps its shape and the
    /// future days show as empty room rather than the chart stretching to fit what exists.
    private func xDomain(_ days: [BudgetMonthStripCalculator.Day]) -> ClosedRange<Date> {
        let first = days.first?.date ?? referenceDate
        let last = days.last?.date ?? referenceDate
        return first...(calendar.date(byAdding: .day, value: 1, to: last) ?? last)
    }

    private func dayAxis(_ days: [BudgetMonthStripCalculator.Day]) -> some AxisContent {
        AxisMarks(values: .stride(by: .day, count: days.count > 14 ? 5 : 1)) { _ in
            AxisValueLabel(format: .dateTime.day())
        }
    }

    private func dayDetail(_ day: BudgetMonthStripCalculator.Day) -> some View {
        let rows = transactions
            .filter { BudgetCalculator.countsTowardBudget($0, selectedAccountIDs: Set(budget.selectedAccountIDs), startDate: budget.startDate, calendar: calendar)
                && calendar.isDate($0.date, inSameDayAs: day.date) }
            .sorted { $0.date > $1.date }
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
