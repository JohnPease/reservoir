import SwiftData
import SwiftUI

/// What each credit card will bill (reservoir-17g): the charges between its statement closing
/// dates, so the payment can be seen coming. The user enters each card's closing and due days;
/// there is no Plaid Liabilities lookup. Refunds and credits are not imported, so a bill with
/// refunds on it comes in a little under what is shown.
struct CardStatementsView: View {
    @Query private var transactions: [SpendTransaction]
    @Environment(TodayClock.self) private var todayClock

    private let linkedAccountStore = LinkedAccountStore()
    private let cycleStore = CardCycleStore()

    @State private var settings: [String: CardCycleSettings] = [:]
    @State private var cards: [LinkedAccount] = []

    var body: some View {
        List {
            if cards.isEmpty {
                Section {
                    Text("Link a credit card in Settings to see what each one will bill.")
                        .foregroundStyle(Color("ReservoirTextSecondary"))
                        .accessibilityIdentifier("statements.empty")
                }
            }
            ForEach(cards, id: \.accountID) { card in
                CardStatementsSection(
                    card: card,
                    settings: binding(for: card),
                    transactions: transactions,
                    now: todayClock.referenceDate
                )
            }
            if !cards.isEmpty {
                Section {} footer: {
                    Text("Totals are the charges imported for each card between its closing dates. Refunds and credits are not imported, so a bill with refunds on it will be a little lower.")
                }
            }
        }
        .navigationTitle("Card statements")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("statements.list")
        .onAppear {
            cards = linkedAccountStore.loadAll().filter { $0.type == "credit" }
            settings = cycleStore.loadAll()
        }
    }

    private func binding(for card: LinkedAccount) -> Binding<CardCycleSettings> {
        Binding(
            get: { settings[card.accountID] ?? CardCycleSettings() },
            set: { newValue in
                settings[card.accountID] = newValue
                cycleStore.save(newValue, accountID: card.accountID)
            }
        )
    }
}

private struct CardStatementsSection: View {
    let card: LinkedAccount
    @Binding var settings: CardCycleSettings
    let transactions: [SpendTransaction]
    let now: Date

    private var title: String {
        card.mask.map { "\(card.name) ••\($0)" } ?? card.name
    }

    private func amount(_ value: Decimal) -> String {
        value.formatted(.currency(code: "USD"))
    }

    private func total(_ cycle: StatementCycleCalculator.Cycle) -> Decimal {
        StatementCycleCalculator.total(of: cycle, accountID: card.accountID, in: transactions)
    }

    private func range(_ cycle: StatementCycleCalculator.Cycle) -> String {
        let format = Date.FormatStyle().month(.abbreviated).day()
        return "\(cycle.start.formatted(format)) – \(cycle.closing.formatted(format))"
    }

    var body: some View {
        Section {
            if let closingDay = settings.closingDay {
                let cycles = StatementCycleCalculator.cycles(
                    closingDay: closingDay, dueDay: settings.dueDay, asOf: now, count: 4
                )
                if let due = StatementCycleCalculator.billDue(in: cycles, asOf: now), let dueDate = due.dueDate {
                    chargesLink(due) {
                        row("Bill due \(dueDate.formatted(.dateTime.month(.abbreviated).day()))", detail: range(due), value: total(due), emphasized: true)
                    }
                    .accessibilityIdentifier("statements.due.\(card.accountID)")
                }
                if let open = cycles.first {
                    chargesLink(open) {
                        row("This cycle so far", detail: "\(range(open)) · closes \(open.closing.formatted(.dateTime.month(.abbreviated).day()))", value: total(open), emphasized: false)
                    }
                    .accessibilityIdentifier("statements.open.\(card.accountID)")
                }
                ForEach(Array(cycles.dropFirst()), id: \.closing) { cycle in
                    chargesLink(cycle) {
                        row(
                            range(cycle),
                            detail: cycle.dueDate.map { "due \($0.formatted(.dateTime.month(.abbreviated).day()))" },
                            value: total(cycle),
                            emphasized: false
                        )
                    }
                    .foregroundStyle(Color("ReservoirTextSecondary"))
                }
            } else {
                Text("Choose the day each statement closes to see this card's bill.")
                    .foregroundStyle(Color("ReservoirTextSecondary"))
                    .accessibilityIdentifier("statements.prompt.\(card.accountID)")
            }
            dayPicker("Statement closes", selection: $settings.closingDay, identifier: "statements.closingPicker.\(card.accountID)")
            dayPicker("Payment due", selection: $settings.dueDay, identifier: "statements.duePicker.\(card.accountID)")
        } header: {
            Text(title)
        }
    }

    private func chargesLink<Row: View>(_ cycle: StatementCycleCalculator.Cycle, @ViewBuilder row: () -> Row) -> some View {
        NavigationLink {
            CardCycleChargesView(
                title: range(cycle),
                accountID: card.accountID,
                cycle: cycle
            )
        } label: {
            row()
        }
    }

    private func row(_ title: String, detail: String?, value: Decimal, emphasized: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(emphasized ? .headline : .body)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(Color("ReservoirTextSecondary"))
                }
            }
            Spacer()
            Text(amount(value))
                .font(emphasized ? .headline : .body)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
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

/// Every charge inside one statement period (reservoir-17g), newest first, read-only.
struct CardCycleChargesView: View {
    let title: String
    let accountID: String
    let cycle: StatementCycleCalculator.Cycle

    @Query private var transactions: [SpendTransaction]
    @Environment(TodayClock.self) private var todayClock

    var body: some View {
        let charges = StatementCycleCalculator.transactions(in: cycle, accountID: accountID, from: transactions)
        let outliers = CategorySpendCalculator.outliers(in: transactions, now: todayClock.referenceDate)
        List {
            if charges.isEmpty {
                Text("No charges in this period").foregroundStyle(.secondary)
                    .accessibilityIdentifier("statements.charges.empty")
            } else {
                Section {
                    ForEach(charges, id: \.persistentModelID) { transaction in
                        TransactionRowView(transaction: transaction, showDate: true, usualAmount: outliers[transaction.persistentModelID])
                            .listRowBackground(Color("ReservoirBackground"))
                    }
                } footer: {
                    let total = charges.reduce(Decimal(0)) { $0 + $1.amount }
                    Text("\(charges.count) \(charges.count == 1 ? "charge" : "charges"), \(total.formatted(.currency(code: "USD")))")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color("ReservoirBackground"))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("statements.charges")
    }
}
