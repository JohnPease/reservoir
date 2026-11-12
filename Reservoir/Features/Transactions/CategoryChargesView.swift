import SwiftData
import SwiftUI

/// The charges behind one category row for one month (reservoir-473), read-only. `detailed`
/// narrows it to one Plaid detailed label; `.none` means the whole category.
struct CategoryChargesView: View {
    let title: String
    let category: String?
    var detailed: String?? = nil
    var merchant: String? = nil
    let month: Date
    /// Shown inside another screen (the wide ledger spread), so it adds no navigation title.
    var isEmbedded = false

    @Query private var transactions: [SpendTransaction]
    @Environment(TodayClock.self) private var todayClock

    var body: some View {
        let interval = Calendar.current.dateInterval(of: .month, for: month)
            ?? DateInterval(start: month, duration: 0)
        let charges = TransactionsScreenCalculator.charges(transactions, category: category, detailed: detailed, merchant: merchant, in: interval)
        let outliers = CategorySpendCalculator.outliers(in: transactions, now: todayClock.referenceDate)
        List {
            if charges.isEmpty {
                Text("No charges").foregroundStyle(.secondary)
            } else {
                Section {
                    ForEach(charges, id: \.persistentModelID) { transaction in
                        TransactionRowView(transaction: transaction, showDate: true, usualAmount: outliers[transaction.persistentModelID])
                            .listRowBackground(Color("ReservoirBackground"))
                    }
                } header: {
                    Text(month.formatted(.dateTime.month(.wide).year()))
                } footer: {
                    let total = charges.reduce(Decimal(0)) { $0 + $1.amount }
                    Text("\(charges.count) \(charges.count == 1 ? "charge" : "charges"), \(total.formatted(.currency(code: "USD")))")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color("ReservoirBackground"))
        .modifier(ChargesTitle(title: title, isEmbedded: isEmbedded))
        .accessibilityIdentifier("categories.charges")
    }
}

private struct ChargesTitle: ViewModifier {
    let title: String
    let isEmbedded: Bool

    func body(content: Content) -> some View {
        if isEmbedded {
            content
        } else {
            content.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        }
    }
}
