import SwiftUI

/// A single `SpendTransaction` row — icon (lock for fixed, cart for variable), merchant
/// name, "Excluded from limit" caption for fixed transactions (or the time for
/// variable), and the amount, all muted via reduced opacity when fixed. Extracted
/// because `TodayView`'s recent-transactions list and `TransactionsView`'s full list
/// duplicated this almost byte-for-byte, differing only in whether a goal-attribution
/// line is shown (STANDARDS.md §3, no copy-paste).
struct TransactionRowView: View {
    let transaction: SpendTransaction
    /// `TransactionsView`'s list shows which goal (or "Unattributed") a transaction is
    /// attributed to; `TodayView`'s recent-transactions list doesn't need this line.
    var showGoalLabel: Bool = false
    /// When set, wraps the row as a single accessibility element under this identifier
    /// (matching `TransactionsView`'s existing `"transactions.row"` XCUITest hook).
    /// `nil` leaves the row's accessibility structure at SwiftUI's default, matching
    /// `TodayView`'s recent-transactions rows, which were never individually identified.
    var accessibilityIdentifier: String?

    private var isFixed: Bool { transaction.type == .fixed }

    private var goalLabel: String {
        transaction.savingsGoal?.displayName ?? "Unattributed"
    }

    var body: some View {
        let row = HStack {
            Image(systemName: isFixed ? "lock.fill" : "cart.fill")
                .foregroundStyle(isFixed ? .secondary : .primary)

            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.merchantName)
                    .foregroundStyle(isFixed ? .secondary : .primary)
                if isFixed {
                    Text("Excluded from limit")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(transaction.date, style: .time)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if showGoalLabel {
                    Text(goalLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("transactions.row.goalLabel")
                }
            }

            Spacer()

            Text(transaction.amount, format: .currency(code: "USD"))
                .foregroundStyle(isFixed ? .secondary : .primary)
        }
        .opacity(isFixed ? 0.6 : 1.0)

        if let accessibilityIdentifier {
            row
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(accessibilityIdentifier)
        } else {
            row
        }
    }
}
