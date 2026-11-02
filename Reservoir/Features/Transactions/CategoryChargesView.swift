import SwiftData
import SwiftUI

/// The charges behind one category row for one month (reservoir-473), read-only. `detailed`
/// narrows it to one Plaid detailed label; `.none` means the whole category.
struct CategoryChargesView: View {
    let title: String
    let category: String?
    var detailed: String?? = nil
    let month: Date

    @Query private var transactions: [SpendTransaction]

    var body: some View {
        let interval = Calendar.current.dateInterval(of: .month, for: month)
            ?? DateInterval(start: month, duration: 0)
        let charges = TransactionsScreenCalculator.charges(transactions, category: category, detailed: detailed, in: interval)
        List {
            if charges.isEmpty {
                Text("No charges").foregroundStyle(.secondary)
            } else {
                Section {
                    ForEach(charges, id: \.persistentModelID) { transaction in
                        TransactionRowView(transaction: transaction, showDate: true)
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
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("categories.charges")
    }
}
