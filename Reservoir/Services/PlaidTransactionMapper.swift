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
    /// Returns `nil` when `transaction.amount <= 0` (a credit/income transaction — see
    /// this type's doc comment) or when `transaction.date` isn't parseable as Plaid's
    /// documented `yyyy-MM-dd` date string.
    ///
    /// - Parameter calendar: Defaults to `.current` (device-local). Exposed as a
    ///   parameter purely so tests can construct a fixed-timezone `Calendar` and prove
    ///   the year/month/day-component construction below is correct independent of
    ///   whatever timezone the test machine happens to run in — production call sites
    ///   should never pass this explicitly.
    static func map(_ transaction: PlaidTransaction, calendar: Calendar = .current) -> MappedPlaidTransaction? {
        guard transaction.amount > 0 else { return nil }
        guard let date = Self.localDate(from: transaction.date, calendar: calendar) else { return nil }
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

    /// Parses Plaid's `yyyy-MM-dd` string into `calendar`'s local midnight for that
    /// calendar day, via `DateComponents` rather than a `DateFormatter` pinned to a
    /// specific `TimeZone` — the latter produces a `Date` anchored to *that* timezone's
    /// midnight, which silently shifts to the *previous* local calendar day once
    /// converted through `Calendar.current.startOfDay(for:)` (as
    /// `TransactionDedupMatcher.findMatch` does) for any device timezone behind the
    /// formatter's. Building the `Date` directly from year/month/day components against
    /// `calendar` sidesteps timezone conversion entirely: `"2026-07-16"` always becomes
    /// local midnight July 16 in whatever calendar is passed in, matching how
    /// `TransactionEntryView`/manual entries date transactions.
    /// `internal` (not `private`) so `UITestSupport.todayForImportTests` can parse its
    /// scripted date string through the exact same path production code uses, rather
    /// than re-implementing date parsing a second time — the drift between those two
    /// implementations (one UTC-pinned `DateFormatter`, one local-calendar
    /// `DateComponents`) is what caused the merge-prompt dedup match to silently fail
    /// on UTC-behind devices in the first place.
    static func localDate(from dateString: String, calendar: Calendar) -> Date? {
        let parts = dateString.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else {
            return nil
        }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return calendar.date(from: components)
    }
}
