import SwiftData
import SwiftUI

/// What each credit card will bill (reservoir-17g): every statement drawn as a bar spanning the
/// dates it covers, one lane per card, so the cards' billing cycles read side by side. Tapping a
/// bar selects that statement; its summary sits below with a link to the charges inside it. The
/// user enters each card's closing and due days; there is no Plaid Liabilities lookup. Refunds and
/// credits are not imported, so a bill with refunds on it comes in a little under what is shown.
struct CardStatementsView: View {
    @Query private var transactions: [SpendTransaction]
    @Environment(TodayClock.self) private var todayClock

    private let linkedAccountStore = LinkedAccountStore()
    private let cycleStore = CardCycleStore()

    @State private var settings: [String: CardCycleSettings] = [:]
    @State private var cards: [LinkedAccount] = []
    @State private var selection: Selection?

    struct Selection: Equatable {
        let accountID: String
        let closing: Date
    }

    private var now: Date { todayClock.referenceDate }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if cards.isEmpty {
                    Text("Link a credit card in Settings to see what each one will bill.")
                        .foregroundStyle(Color("ReservoirTextSecondary"))
                        .accessibilityIdentifier("statements.empty")
                } else {
                    lanes
                    if let selected = selectedStatement {
                        StatementSummary(
                            card: selected.card,
                            cycle: selected.cycle,
                            transactions: transactions,
                            now: now,
                            laneIndex: selected.laneIndex
                        )
                        CardCycleChargesList(accountID: selected.card.accountID, cycle: selected.cycle)
                    }
                    Text("Totals are the charges imported for each card between its closing dates. Refunds and credits are not imported, so a bill with refunds on it will be a little lower.")
                        .font(.footnote)
                        .foregroundStyle(Color("ReservoirTextSecondary"))
                }
            }
            .padding()
        }
        .background(Color("ReservoirBackground"))
        .navigationTitle("Statements")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !cards.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        CardCycleSettingsView(cards: cards, settings: $settings, store: cycleStore)
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Statement days")
                    .accessibilityIdentifier("statements.settingsLink")
                }
            }
        }
        .accessibilityIdentifier("statements.list")
        .onAppear {
            cards = linkedAccountStore.loadAll().filter { $0.type == "credit" }
            settings = cycleStore.loadAll()
        }
    }

    // MARK: - Lanes

    private var laneData: [StatementLanes.Lane] {
        cards.enumerated().map { index, card in
            let cycles = settings[card.accountID]?.closingDay.map {
                StatementCycleCalculator.cycles(
                    closingDay: $0, dueDay: settings[card.accountID]?.dueDay, asOf: now, count: 6
                )
            } ?? []
            return StatementLanes.Lane(card: card, index: index, cycles: cycles)
        }
    }

    private var lanes: some View {
        let data = laneData
        return VStack(alignment: .leading, spacing: 10) {
            StatementLanes(
                lanes: data,
                transactions: transactions,
                now: now,
                selection: selection,
                onSelect: { accountID, closing in
                    let tapped = Selection(accountID: accountID, closing: closing)
                    withAnimation { selection = selection == tapped ? nil : tapped }
                }
            )
            HStack(spacing: 4) {
                Image(systemName: "arrowtriangle.down.fill").font(.system(size: 9))
                Text("Payment due")
            }
            .font(.caption2)
            .foregroundStyle(Color("ReservoirTextSecondary"))
            .accessibilityHidden(true)
            ForEach(data.filter { $0.cycles.isEmpty }, id: \.card.accountID) { lane in
                Text("Choose the day \(lane.title) closes its statement (gear, top right).")
                    .font(.footnote)
                    .foregroundStyle(Color("ReservoirTextSecondary"))
                    .accessibilityIdentifier("statements.prompt.\(lane.card.accountID)")
            }
        }
        .padding(12)
        .reservoirCardBackground()
    }

    private var selectedStatement: (card: LinkedAccount, cycle: StatementCycleCalculator.Cycle, laneIndex: Int)? {
        let data = laneData
        guard let current = selection,
              let lane = data.first(where: { $0.card.accountID == current.accountID }),
              let cycle = lane.cycles.first(where: { $0.closing == current.closing })
        else { return nil }
        return (lane.card, cycle, lane.index)
    }
}

/// Palette for the lanes, in card order.
enum StatementLanePalette {
    static func color(_ index: Int) -> Color {
        [Color("ReservoirAccent"), Color("ReservoirDropletDeficit"), Color("ReservoirTextSecondary")][index % 3]
    }
}

/// The drawing: months along the top, one lane per card, a bar per statement, a flag where each
/// bill is due and a line for today. Bars are buttons.
struct StatementLanes: View {
    struct Lane {
        let card: LinkedAccount
        let index: Int
        let cycles: [StatementCycleCalculator.Cycle]
        var title: String { card.mask.map { "\(card.name) ••\($0)" } ?? card.name }
    }

    let lanes: [Lane]
    let transactions: [SpendTransaction]
    let now: Date
    let selection: CardStatementsView.Selection?
    let onSelect: (String, Date) -> Void

    private let calendar = Calendar.current
    private static let laneHeight: CGFloat = 62
    private static let headerHeight: CGFloat = 16

    /// From the first of the month two back to the end of next month, so a closed statement or
    /// two shows behind today and the next bill ahead of it.
    private var window: (start: Date, end: Date) {
        let today = calendar.startOfDay(for: now)
        let monthStart = calendar.dateInterval(of: .month, for: today)?.start ?? today
        let start = calendar.date(byAdding: .month, value: -2, to: monthStart) ?? monthStart
        let end = calendar.date(byAdding: .month, value: 2, to: monthStart) ?? monthStart
        return (start, end)
    }

    var body: some View {
        let window = window
        let span = window.end.timeIntervalSince(window.start)
        GeometryReader { proxy in
            let width = proxy.size.width
            let x: (Date) -> CGFloat = { date in
                CGFloat(date.timeIntervalSince(window.start) / span) * width
            }
            ZStack(alignment: .topLeading) {
                months(window: window, x: x, width: width)
                ForEach(lanes, id: \.card.accountID) { lane in
                    laneView(lane, x: x, window: window)
                        .offset(y: Self.headerHeight + CGFloat(lane.index) * Self.laneHeight)
                }
                let todayX = x(calendar.startOfDay(for: now))
                Rectangle()
                    .fill(Color("ReservoirDeficit"))
                    .frame(width: 1.5, height: totalHeight - Self.headerHeight + 4)
                    .offset(x: todayX, y: Self.headerHeight - 2)
                    .accessibilityHidden(true)
                Text("Today")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color("ReservoirDeficit"))
                    .position(x: min(max(todayX, 18), width - 18), y: totalHeight + 6)
            }
        }
        .frame(height: totalHeight + 16)
    }

    private var totalHeight: CGFloat { Self.headerHeight + CGFloat(lanes.count) * Self.laneHeight }

    private func months(window: (start: Date, end: Date), x: @escaping (Date) -> CGFloat, width: CGFloat) -> some View {
        let starts = stride(from: 0, to: 4, by: 1).compactMap { calendar.date(byAdding: .month, value: $0, to: window.start) }
        return ZStack(alignment: .topLeading) {
            ForEach(starts, id: \.self) { month in
                Rectangle().fill(Color("ReservoirDropletTrack")).frame(width: 1, height: totalHeight - 4).offset(x: x(month))
                Text(month.formatted(.dateTime.month(.abbreviated)))
                    .font(.caption2)
                    .foregroundStyle(Color("ReservoirTextSecondary"))
                    .offset(x: x(month) + 3, y: -1)
            }
        }
        .accessibilityHidden(true)
    }

    private func laneView(_ lane: Lane, x: @escaping (Date) -> CGFloat, window: (start: Date, end: Date)) -> some View {
        let color = StatementLanePalette.color(lane.index)
        return ZStack(alignment: .topLeading) {
            Text(lane.title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(color)
                .offset(x: 2, y: 2)
                .accessibilityHidden(true)
            ForEach(lane.cycles, id: \.closing) { cycle in
                let end = calendar.date(byAdding: .day, value: 1, to: cycle.closing) ?? cycle.closing
                let left = max(x(cycle.start), 0)
                let right = x(end)
                if right > 0, left < x(window.end) {
                    bar(lane: lane, cycle: cycle, color: color, left: left, width: max(right - left - 1.5, 2))
                }
                if let due = cycle.dueDate, due >= window.start, due < window.end {
                    Image(systemName: "arrowtriangle.down.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(color)
                        .position(x: x(due), y: 46)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    private func bar(lane: Lane, cycle: StatementCycleCalculator.Cycle, color: Color, left: CGFloat, width: CGFloat) -> some View {
        let total = StatementCycleCalculator.total(of: cycle, accountID: lane.card.accountID, in: transactions)
        let isSelected = selection == .init(accountID: lane.card.accountID, closing: cycle.closing)
        let range = StatementFormatting.range(cycle)
        let label = "\(lane.title), \(range), \(cycle.isOpen ? "open" : "closed"), \(total.formatted(.currency(code: "USD")))"
        return Button {
            onSelect(lane.card.accountID, cycle.closing)
        } label: {
            RoundedRectangle(cornerRadius: 6)
                .fill(color.opacity(cycle.isOpen ? 1 : 0.55))
                .overlay {
                    if width > 46 {
                        Text(total.formatted(.currency(code: "USD").precision(.fractionLength(0))))
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Color("ReservoirOnAccent"))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color("ReservoirTextPrimary"), lineWidth: isSelected ? 2 : 0)
                }
        }
        .buttonStyle(.plain)
        .frame(width: width, height: 28)
        .offset(x: left, y: 16)
        .accessibilityLabel(label)
        .accessibilityIdentifier(cycle.isOpen ? "statements.open.\(lane.card.accountID)" : "statements.bar.\(lane.card.accountID).\(Int(cycle.closing.timeIntervalSince1970))")
    }
}

enum StatementFormatting {
    static func range(_ cycle: StatementCycleCalculator.Cycle) -> String {
        let format = Date.FormatStyle().month(.abbreviated).day()
        return "\(cycle.start.formatted(format)) – \(cycle.closing.formatted(format))"
    }
}

/// The selected statement: its range, status, total, and the way into its charges.
private struct StatementSummary: View {
    let card: LinkedAccount
    let cycle: StatementCycleCalculator.Cycle
    let transactions: [SpendTransaction]
    let now: Date
    let laneIndex: Int

    private let calendar = Calendar.current

    private var charges: [SpendTransaction] {
        StatementCycleCalculator.transactions(in: cycle, accountID: card.accountID, from: transactions)
    }

    private var status: (text: String, isDue: Bool) {
        let today = calendar.startOfDay(for: now)
        if cycle.isOpen {
            let days = calendar.dateComponents([.day], from: today, to: cycle.closing).day ?? 0
            return (days <= 0 ? "Open · closes today" : "Open · closes in \(days) \(days == 1 ? "day" : "days")", false)
        }
        if let due = cycle.dueDate, due >= today {
            return ("Due \(due.formatted(.dateTime.month(.abbreviated).day()))", true)
        }
        return ("Closed", false)
    }

    var body: some View {
        let total = charges.reduce(Decimal.zero) { $0 + $1.amount }
        let status = status
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(StatementFormatting.range(cycle))
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Color("ReservoirTextPrimary"))
                Spacer()
                Text(status.text)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(status.isDue ? Color("ReservoirDeficit") : Color("ReservoirSurfaceAccent"), in: Capsule())
                    .foregroundStyle(status.isDue ? Color("ReservoirOnAccent") : Color("ReservoirAccent"))
            }
            HStack(alignment: .firstTextBaseline) {
                Text(card.mask.map { "\(card.name) ••\($0)" } ?? card.name)
                    .font(.subheadline)
                    .foregroundStyle(Color("ReservoirTextSecondary"))
                Spacer()
                Text(total, format: .currency(code: "USD"))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color("ReservoirTextPrimary"))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .reservoirCardBackground()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("statements.summary")
    }
}

/// Each card's statement closing day and payment due day.
struct CardCycleSettingsView: View {
    let cards: [LinkedAccount]
    @Binding var settings: [String: CardCycleSettings]
    let store: CardCycleStore

    var body: some View {
        List {
            ForEach(cards, id: \.accountID) { card in
                Section {
                    dayPicker("Statement closes", selection: binding(card).closingDay, identifier: "statements.closingPicker.\(card.accountID)")
                    dayPicker("Payment due", selection: binding(card).dueDay, identifier: "statements.duePicker.\(card.accountID)")
                } header: {
                    Text(card.mask.map { "\(card.name) ••\($0)" } ?? card.name)
                }
            }
        }
        .navigationTitle("Statement days")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func binding(_ card: LinkedAccount) -> Binding<CardCycleSettings> {
        Binding(
            get: { settings[card.accountID] ?? CardCycleSettings() },
            set: { newValue in
                settings[card.accountID] = newValue
                store.save(newValue, accountID: card.accountID)
            }
        )
    }

    private func dayPicker(_ label: String, selection: Binding<Int?>, identifier: String) -> some View {
        Picker(label, selection: selection) {
            Text("Not set").tag(Int?.none)
            ForEach(1...31, id: \.self) { day in
                Text(Self.ordinal(day)).tag(Int?.some(day))
            }
        }
        .accessibilityIdentifier(identifier)
    }

    private static func ordinal(_ day: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        return "the " + (formatter.string(from: NSNumber(value: day)) ?? "\(day)")
    }
}

/// Every charge inside the selected statement (reservoir-17g), shown under its summary, with
/// the same sort and group-by-category choices the Transactions list offers.
struct CardCycleChargesList: View {
    let accountID: String
    let cycle: StatementCycleCalculator.Cycle

    @Query private var transactions: [SpendTransaction]
    @Environment(TodayClock.self) private var todayClock
    @State private var sort: StatementCycleCalculator.ChargeSort = .date
    @State private var groupByCategory = false

    var body: some View {
        let charges = StatementCycleCalculator.transactions(in: cycle, accountID: accountID, from: transactions)
        let outliers = CategorySpendCalculator.outliers(in: transactions, now: todayClock.referenceDate)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                let total = charges.reduce(Decimal(0)) { $0 + $1.amount }
                Text("\(charges.count) \(charges.count == 1 ? "charge" : "charges"), \(total.formatted(.currency(code: "USD")))")
                    .font(.subheadline)
                    .foregroundStyle(Color("ReservoirTextSecondary"))
                Spacer()
                Menu {
                    Picker("Sort by", selection: $sort) {
                        ForEach(StatementCycleCalculator.ChargeSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Toggle("Group by category", isOn: $groupByCategory)
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .accessibilityLabel("Sort and group")
                .accessibilityIdentifier("statements.charges.options")
            }
            if charges.isEmpty {
                Text("No charges in this period")
                    .foregroundStyle(Color("ReservoirTextSecondary"))
                    .accessibilityIdentifier("statements.charges.empty")
            } else if groupByCategory {
                ForEach(StatementCycleCalculator.grouped(charges, by: sort), id: \.name) { group in
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text(group.name)
                            Spacer()
                            Text(group.total.formatted(.currency(code: "USD"))).monospacedDigit()
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color("ReservoirTextSecondary"))
                        .padding(.vertical, 6)
                        rows(group.charges, outliers: outliers)
                    }
                }
            } else {
                rows(StatementCycleCalculator.sorted(charges, by: sort), outliers: outliers)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("statements.charges")
    }

    private func rows(_ charges: [SpendTransaction], outliers: [PersistentIdentifier: Decimal]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(charges.enumerated()), id: \.element.persistentModelID) { index, transaction in
                if index > 0 { Divider() }
                TransactionRowView(transaction: transaction, showDate: true, usualAmount: outliers[transaction.persistentModelID])
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }
        }
        .reservoirCardBackground()
    }
}
