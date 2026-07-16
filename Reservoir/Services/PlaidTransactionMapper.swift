import Foundation

/// A Plaid `/transactions/sync` transaction, mapped to this app's domain shape.
/// Pure value type — no `SwiftData` dependency — so `TransactionDedupMatcher` and
/// `TransactionImportService` can operate on it without a live `ModelContext`.
struct MappedPlaidTransaction: Equatable {
    let plaidTransactionID: String
    let amount: Decimal
    let date: Date
    let merchantName: String
}

/// Maps Plaid's wire-format `PlaidTransaction` (see `TransactionImportService`'s DTOs)
/// to `MappedPlaidTransaction`. Isolates the one place amount-sign, date-parsing, and
/// merchant-name-fallback decisions are made, per the bead's flagged verification item.
///
/// **Amount sign (verified 2026-07-15 against Plaid's `/transactions/sync` docs)**:
/// Plaid's `amount` is positive when money moves out of the account (debit/expense) and
/// negative when money moves in (credit/income, refunds, direct deposits) — see
/// https://plaid.com/docs/api/products/transactions/#transactionssync. This app only
/// tracks spend (`SpendTransaction.amount` is always positive — manual entry's
/// `TransactionEntryValidator.validateAmount` rejects <= 0), and has no
/// income-tracking concept, so a Plaid `amount <= 0` (a credit) is not spend to import
/// at all — `map` returns `nil` for those rather than flipping the sign and recording
/// a refund/paycheck as spend. A positive Plaid `amount` already matches this app's
/// sign convention directly, with no inversion needed.
enum PlaidTransactionMapper {
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// Returns `nil` when `transaction.amount <= 0` (a credit/income transaction — see
    /// this type's doc comment) or when `transaction.date` isn't parseable as Plaid's
    /// documented `yyyy-MM-dd` date string.
    static func map(_ transaction: PlaidTransaction) -> MappedPlaidTransaction? {
        guard transaction.amount > 0 else { return nil }
        guard let date = dateFormatter.date(from: transaction.date) else { return nil }
        let merchantName = transaction.merchant_name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = (merchantName?.isEmpty == false ? merchantName : nil)
            ?? transaction.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedName.isEmpty else { return nil }

        return MappedPlaidTransaction(
            plaidTransactionID: transaction.transaction_id,
            amount: transaction.amount,
            date: date,
            merchantName: resolvedName
        )
    }
}
