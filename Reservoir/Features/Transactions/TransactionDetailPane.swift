import SwiftUI

/// The right-hand pane of `TransactionsView` on wide screens (reservoir-h2k): the selected
/// charge at a glance, with the same Edit and Delete actions the narrow layout reaches
/// through a sheet and a swipe. Presentation only.
struct TransactionDetailPane: View {
    let transaction: SpendTransaction
    var usualAmount: Decimal?
    let onEdit: () -> Void
    let onDelete: () -> Void

    private var categoryText: String? {
        guard let category = transaction.category else { return nil }
        let main = CategorySpendCalculator.displayName(for: category)
        guard transaction.categoryDetailed != nil else { return main }
        return "\(main) · \(CategorySpendCalculator.displayName(forDetailed: transaction.categoryDetailed, in: category))"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(transaction.merchantName)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Color("ReservoirTextPrimary"))
                    Text(transaction.amount, format: .currency(code: "USD"))
                        .font(.system(size: 48, weight: .bold))
                        .foregroundStyle(Color("ReservoirTextPrimary"))
                    if let usualAmount {
                        Text("Usually about \(usualAmount.wholeDollarText)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color("ReservoirDeficit"))
                    }
                }

                VStack(spacing: 0) {
                    detailRow("Date", transaction.date.formatted(date: .complete, time: .shortened))
                    if let categoryText { detailRow("Category", categoryText) }
                    detailRow("Counts toward", transaction.type == .fixed
                              ? "Nothing (fixed expense)" : (transaction.savingsGoal?.displayName ?? "Unattributed"))
                    if transaction.isPending { detailRow("Status", "Pending") }
                    detailRow("Added", transaction.entryMethod == .imported ? "Imported from your bank" : "Entered by hand")
                }
                .padding(.horizontal)
                .reservoirCardBackground(Color("ReservoirSurface"))

                HStack(spacing: 12) {
                    Button("Edit", action: onEdit)
                        .buttonStyle(ReservoirPrimaryButtonStyle())
                        .accessibilityIdentifier("transactions.detail.edit")
                    Button("Delete", role: .destructive, action: onDelete)
                        .accessibilityIdentifier("transactions.detail.delete")
                }
            }
            .padding()
            .frame(maxWidth: 520, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color("ReservoirBackground"))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transactions.detail")
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(Color("ReservoirTextSecondary"))
            Spacer(minLength: 16)
            Text(value)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(Color("ReservoirTextPrimary"))
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// Shown in the detail pane until a row is chosen.
struct TransactionDetailPlaceholder: View {
    var body: some View {
        ContentUnavailableView("Select a transaction", systemImage: "list.bullet.rectangle",
                               description: Text("Its details show here."))
            .background(Color("ReservoirBackground"))
            .accessibilityIdentifier("transactions.detailPlaceholder")
    }
}
