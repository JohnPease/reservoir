import SwiftUI

/// A single `SpendTransaction` row — 30x30pt circular direction-icon backdrop, merchant
/// name, "Excluded from limit" caption for fixed transactions (or the time for
/// variable), and the amount, all muted via reduced opacity when fixed. Extracted
/// because `TodayView`'s recent-transactions list and `TransactionsView`'s full list
/// duplicated this almost byte-for-byte, differing only in whether a goal-attribution
/// line is shown (STANDARDS.md §3, no copy-paste).
///
/// The icon was previously a static lock-for-fixed/cart-for-variable glyph; per
/// `docs/TODAY_SCREEN_REDESIGN_REQUIREMENTS.md` §3.4 the shopping-cart glyph
/// misrepresented non-purchase transactions (payroll, transfers) and is replaced with a
/// direction glyph derived from the transaction's amount sign, for every row regardless
/// of `type` — the spec describes one icon scheme for the whole row set, not a
/// fixed/variable split, so the fixed/variable distinction now lives solely in the
/// opacity + "Excluded from limit" caption already below.
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

    /// A debit removes from the balance. `SpendTransaction.amount` is always positive
    /// today — `PlaidTransactionMapper` drops credits/income at import time entirely,
    /// and manual entry has no income-tracking concept — so every row currently renders
    /// as a debit. The sign check (rather than a hardcoded `true`) matches §3.4's rule
    /// ("direction is derived from the existing Plaid transaction amount sign") as
    /// stated, so a credit row renders correctly the moment one ever exists in the data
    /// model, with no further change needed here.
    private var isDebit: Bool { transaction.amount >= 0 }

    private var goalLabel: String {
        transaction.savingsGoal?.displayName ?? "Unattributed"
    }

    var body: some View {
        let row = HStack {
            TransactionDirectionIcon(isDebit: isDebit)

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

/// The 30x30pt circular icon backdrop + direction glyph, §3.4: debit gets
/// `ReservoirSurfaceDeficit`/`arrow.down.right`/`ReservoirDeficit`; credit gets
/// `ReservoirSurfaceAccent`/`arrow.up.right`/`ReservoirAccent`. Its own small view
/// (rather than inlined into `TransactionRowView`'s `HStack`) so the backdrop-plus-glyph
/// pairing stays a single reusable unit — `docs/DESIGN_STANDARDS.md` §3 calls this
/// pairing out as "the standard pattern for any future status-driven icon," so keeping
/// it as one named type here makes it easy to reuse verbatim elsewhere later.
private struct TransactionDirectionIcon: View {
    let isDebit: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(isDebit ? Color("ReservoirSurfaceDeficit") : Color("ReservoirSurfaceAccent"))
            Image(systemName: isDebit ? "arrow.down.right" : "arrow.up.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isDebit ? Color("ReservoirDeficit") : Color("ReservoirAccent"))
        }
        .frame(width: 30, height: 30)
    }
}
