import SwiftData
import SwiftUI

/// Read-only "Spending by category" screen (reservoir-27a, reservoir-hnt): one month at a
/// time, using Plaid's categories as imported, each row compared with the month before.
/// Presentation only; the grouping is `CategorySpendCalculator`.
struct CategoryBreakdownView: View {
    @Query private var transactions: [SpendTransaction]
    @Environment(TodayClock.self) private var todayClock

    @State private var monthOffset = 0
    /// The category open on the right-hand page when the screen is wide (reservoir-wrx); nil
    /// until one is picked, which shows the biggest.
    @State private var selection: Pick?

    /// A row's identity; a struct because a nil category (uncategorized) is a row of its own.
    private struct Pick: Hashable { var category: String? }

    private let calendar = Calendar.current

    var body: some View {
        GeometryReader { proxy in
            breakdown(wide: ScreenLayout.layout(for: proxy.size) != .column)
        }
        .navigationTitle("Spending by category")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func breakdown(wide: Bool) -> some View {
        let month = displayedMonth
        let entries = transactions.map(CategorySpendCalculator.Entry.init)
        let summary = CategorySpendCalculator.month(
            containing: month, entries: entries, now: todayClock.referenceDate, calendar: calendar
        )
        let selected = summary.rows.first { Pick(category: $0.category) == selection } ?? summary.rows.first
        let selectedPick = selected.map { Pick(category: $0.category) }
        let list = List {
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
            let recurring = RecurringChargeCalculator.detect(entries: entries, now: todayClock.referenceDate, calendar: calendar)
            if !recurring.isEmpty {
                Section {
                    NavigationLink {
                        RecurringChargesView()
                    } label: {
                        HStack {
                            Text("Recurring charges")
                            Spacer()
                            Text("\(recurring.count) · about \(RecurringChargeCalculator.monthlyTotal(recurring).wholeDollarText) a month")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("categories.recurringLink")
                }
            }
            let callouts = CategorySpendCalculator.callouts(
                month: month, entries: entries, now: todayClock.referenceDate, calendar: calendar
            )
            if !callouts.isEmpty {
                Section("Higher than usual") {
                    ForEach(callouts, id: \.category) { callout in
                        CalloutRowView(callout: callout)
                    }
                }
                .accessibilityIdentifier("categories.callouts")
            }
            let projections = CategorySpendCalculator.projections(
                month: month, entries: entries, now: todayClock.referenceDate, calendar: calendar
            )
            if !projections.isEmpty {
                Section {
                    ForEach(projections, id: \.category) { projection in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(projection.text)
                            Text(projection.detailText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                } header: {
                    Text("On pace to run high")
                } footer: {
                    Text("This month's spend so far, spread over the whole month.")
                }
                .accessibilityIdentifier("categories.projections")
            }
            if summary.rows.isEmpty {
                Section { Text("No spending this month").foregroundStyle(.secondary) }
            } else {
                Section {
                    ForEach(summary.rows, id: \.category) { row in
                        let usual = CategorySpendCalculator.usualMonthly(for: row.category, before: month, entries: entries, calendar: calendar)?.average
                        let label = CategoryRowView(row: row, usual: usual)
                        if wide {
                            Button { selection = Pick(category: row.category) } label: { label }
                                .buttonStyle(.plain)
                                .listRowBackground(Pick(category: row.category) == selectedPick ? Color("ReservoirSurfaceAccent") : nil)
                                .accessibilityAddTraits(Pick(category: row.category) == selectedPick ? .isSelected : [])
                        } else {
                            NavigationLink {
                                CategoryTrendView(category: row.category, month: month)
                            } label: {
                                label
                            }
                        }
                    }
                } footer: {
                    Text(footer(for: summary))
                }
            }
        }
        if wide {
            HStack(spacing: 0) {
                list.frame(maxWidth: 420)
                Divider()
                if let selected {
                    CategoryLedgerPage(row: selected, month: month, entries: entries, calendar: calendar)
                        .id(Pick(category: selected.category))
                } else {
                    Color.clear
                }
            }
        } else {
            list
        }
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
    /// What this category usually comes to in a month, from earlier months; nil with too little history.
    var usual: Decimal?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(row.name)
                Spacer()
                Text(row.amount.formatted(.currency(code: "USD")))
                    .monospacedDigit()
            }
            UsualBar(amount: row.amount, usual: usual)
            HStack {
                Text("\(row.count) \(row.count == 1 ? "charge" : "charges")")
                if let usual {
                    Text("· usual \(usual.wholeDollarText)")
                }
                Spacer()
                changeLabel
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var changeLabel: some View {
        let change = row.change
        if change == 0 {
            Text("no change")
        } else {
            let amount = abs(change).wholeDollarText
            Label(
                change > 0 ? "up \(amount)" : "down \(amount)",
                systemImage: change > 0 ? "arrow.up" : "arrow.down"
            )
            .foregroundStyle(change > 0 ? Color("ReservoirDeficit") : Color("ReservoirTextSecondary"))
        }
    }
}

/// One "higher than usual" line (reservoir-qj2): the headline and the dollar comparison.
struct CalloutRowView: View {
    let callout: CategorySpendCalculator.Callout

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(callout.text, systemImage: "exclamationmark.circle")
                .foregroundStyle(Color("ReservoirDeficit"))
            Text(callout.detailText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A category's spend as a bar with a tick at its usual month, both on one scale (the larger of
/// the two fills the track). Without a usual it is just the bar.
private struct UsualBar: View {
    let amount: Decimal
    let usual: Decimal?

    var body: some View {
        GeometryReader { proxy in
            let scale = max(amount, usual ?? 0)
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color("ReservoirDropletTrack"))
                Capsule().fill(Color("ReservoirAccent"))
                    .frame(width: width * fraction(amount, of: scale))
                if let usual, usual > 0 {
                    Rectangle()
                        .fill(Color("ReservoirTextPrimary"))
                        .frame(width: 2, height: 12)
                        .offset(x: max(width * fraction(usual, of: scale) - 1, 0))
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 12)
        .accessibilityHidden(true)
    }

    private func fraction(_ value: Decimal, of scale: Decimal) -> CGFloat {
        guard scale > 0 else { return 0 }
        return CGFloat(NSDecimalNumber(decimal: value / scale).doubleValue)
    }
}

/// The right-hand page of the wide layout (reservoir-wrx): one category's month, its usual, and
/// the charges behind it, with a link to the full trend. Replaces pushing a screen.
private struct CategoryLedgerPage: View {
    let row: CategorySpendCalculator.Row
    let month: Date
    let entries: [CategorySpendCalculator.Entry]
    let calendar: Calendar

    var body: some View {
        let usual = CategorySpendCalculator.usualMonthly(for: row.category, before: month, entries: entries, calendar: calendar)?.average
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name)
                        .font(.title3.weight(.semibold))
                    Text(subtitle(usual: usual))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                NavigationLink {
                    CategoryTrendView(category: row.category, month: month)
                } label: {
                    Label("Trend", systemImage: "chart.bar")
                }
                .accessibilityIdentifier("categories.ledger.trend")
            }
            .padding()
            .background(Color("ReservoirBackground"))
            CategoryChargesView(title: row.name, category: row.category, month: month, isEmbedded: true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("categories.ledger")
    }

    private func subtitle(usual: Decimal?) -> String {
        var text = row.amount.wholeDollarText
        if let usual { text += " · usual \(usual.wholeDollarText) a month" }
        return text
    }
}
