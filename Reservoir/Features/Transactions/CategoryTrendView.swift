import Charts
import SwiftData
import SwiftUI

/// One category's trend (reservoir-hnt): monthly bars over 6 or 12 months, the same month a year
/// earlier when the history reaches it, a higher-than-usual note, the month's charges, top
/// merchants, the Plaid detailed-label split and a day-of-week pattern. Presentation only; the
/// numbers come from `CategorySpendCalculator`.
struct CategoryTrendView: View {
    let category: String?
    /// The month the user was looking at; the chart ends here.
    let month: Date

    @Query private var transactions: [SpendTransaction]
    @Environment(TodayClock.self) private var todayClock
    @State private var range: Span = .sixMonths

    private let calendar = Calendar.current
    private static let topMerchantCount = 5

    enum Span: Int, CaseIterable, Identifiable {
        case sixMonths = 6
        case twelveMonths = 12
        var id: Int { rawValue }
        var label: String { self == .sixMonths ? "6 months" : "12 months" }
    }

    var body: some View {
        let entries = transactions.map(CategorySpendCalculator.Entry.init)
        let name = CategorySpendCalculator.displayName(for: category)
        let history = CategorySpendCalculator.history(
            for: category, months: range.rawValue, endingAt: month, entries: entries, calendar: calendar
        )
        let callout = CategorySpendCalculator.callouts(
            month: month, entries: entries, now: todayClock.referenceDate, calendar: calendar
        ).first { $0.category == category }
        let detail = CategorySpendCalculator.detail(
            for: category, month: month, entries: entries, now: todayClock.referenceDate, calendar: calendar
        )
        let merchants = CategorySpendCalculator.merchants(
            for: category, month: month, entries: entries, now: todayClock.referenceDate, calendar: calendar
        ).filter { $0.amount > 0 }.prefix(Self.topMerchantCount)
        let weekdays = CategorySpendCalculator.weekdayPattern(
            for: category, months: range.rawValue, endingAt: month, entries: entries, calendar: calendar
        )
        let lastYear = CategorySpendCalculator.sameMonthLastYear(for: category, month: month, entries: entries, calendar: calendar)
        let thisMonthAmount = history.last?.amount ?? 0

        List {
            if let callout {
                Section { CalloutRowView(callout: callout) }
            }
            Section {
                Picker("Range", selection: $range) {
                    ForEach(Span.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("categories.range")
                Chart(history, id: \.monthStart) { item in
                    BarMark(
                        x: .value("Month", item.monthStart, unit: .month),
                        y: .value("Spent", NSDecimalNumber(decimal: item.amount).doubleValue)
                    )
                    .foregroundStyle(item.monthStart == history.last?.monthStart ? Color("ReservoirAccent") : Color("ReservoirTextMuted"))
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .month)) { _ in
                        AxisValueLabel(format: .dateTime.month(.narrow))
                    }
                }
                .frame(height: 200)
                .accessibilityIdentifier("categories.trendChart")
            } footer: {
                footer(
                    usual: CategorySpendCalculator.usualMonthly(for: category, before: month, entries: entries, calendar: calendar),
                    lastYear: lastYear, thisMonth: thisMonthAmount
                )
            }
            Section {
                NavigationLink {
                    CategoryChargesView(title: name, category: category, month: month)
                } label: {
                    Text("See \(month.formatted(.dateTime.month(.wide))) charges")
                }
                .accessibilityIdentifier("categories.seeCharges")
            }
            if !merchants.isEmpty {
                Section("Top merchants") {
                    ForEach(Array(merchants), id: \.name) { row in
                        NavigationLink {
                            CategoryChargesView(title: row.name, category: category, merchant: row.name, month: month)
                        } label: {
                            ComparisonRowView(name: row.name, amount: row.amount, count: row.count, change: row.change)
                        }
                    }
                }
                .accessibilityIdentifier("categories.merchants")
            }
            if detail.count > 1 || detail.first?.detailed != nil {
                Section("Within \(name)") {
                    ForEach(detail, id: \.detailed) { row in
                        NavigationLink {
                            CategoryChargesView(title: row.name, category: category, detailed: .some(row.detailed), month: month)
                        } label: {
                            ComparisonRowView(name: row.name, amount: row.amount, count: row.count, change: row.change)
                        }
                    }
                }
                .accessibilityIdentifier("categories.detail")
            }
            if let weekdays {
                Section {
                    WeekdayChartView(pattern: weekdays, calendar: calendar)
                } header: {
                    Text("Day of week")
                } footer: {
                    Text(weekdayInsight(weekdays))
                }
                .accessibilityIdentifier("categories.weekdays")
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
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func footer(usual: (average: Decimal, months: Int)?, lastYear: Decimal?, thisMonth: Decimal) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // The same "usual" the callouts use: earlier months only, none before the data begins.
            if let usual {
                Text("Average of the earlier \(usual.months) months: \(usual.average.wholeDollarText).")
            }
            if let lastYear {
                Text(lastYearText(lastYear: lastYear, thisMonth: thisMonth))
                    .accessibilityIdentifier("categories.lastYear")
            }
        }
    }

    private func lastYearText(lastYear: Decimal, thisMonth: Decimal) -> String {
        let monthName = month.formatted(.dateTime.month(.wide))
        let change = thisMonth - lastYear
        let direction = change == 0 ? "the same" : (change > 0 ? "up \(change.wholeDollarText)" : "down \((-change).wholeDollarText)")
        return "\(monthName) last year: \(lastYear.wholeDollarText), so this year is \(direction)."
    }

    private func weekdayInsight(_ pattern: CategorySpendCalculator.WeekdayPattern) -> String {
        guard let busiest = pattern.busiest else { return "" }
        let day = calendar.weekdaySymbols[busiest.weekday - 1]
        let percent = Int((pattern.busiestShare * 100).rounded())
        return "Most on \(day)s: \(percent)% of spend over \(range.rawValue) months (\(pattern.chargeCount) charges)."
    }
}

/// A merchant or detailed-label row: name and amount, then the charge count and the change on
/// the comparison window.
private struct ComparisonRowView: View {
    let name: String
    let amount: Decimal
    let count: Int
    let change: Decimal

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(name)
                Spacer()
                Text(amount.formatted(.currency(code: "USD")))
                    .monospacedDigit()
            }
            HStack {
                Text("\(count) \(count == 1 ? "charge" : "charges")")
                Spacer()
                if change != 0 {
                    Text(change > 0 ? "up \(abs(change).wholeDollarText)" : "down \(abs(change).wholeDollarText)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct WeekdayChartView: View {
    let pattern: CategorySpendCalculator.WeekdayPattern
    let calendar: Calendar

    var body: some View {
        Chart(pattern.days, id: \.weekday) { day in
            BarMark(
                x: .value("Day", String(day.weekday)),
                y: .value("Spent", NSDecimalNumber(decimal: day.amount).doubleValue)
            )
            .foregroundStyle(day.weekday == pattern.busiest?.weekday ? Color("ReservoirAccent") : Color("ReservoirTextMuted"))
        }
        .chartXAxis {
            AxisMarks { value in
                AxisValueLabel {
                    if let tag = value.as(String.self), let weekday = Int(tag) {
                        Text(calendar.veryShortWeekdaySymbols[weekday - 1])
                    }
                }
            }
        }
        .frame(height: 140)
        .accessibilityIdentifier("categories.weekdayChart")
    }
}
