import Foundation
import SwiftData

/// Pure dedup-detection and merge-resolution logic for transaction import (adq.6.3).
/// Mirrors `MerchantRuleRetagCalculator`'s pattern: imports `Foundation`+`SwiftData` only
/// for the `@Model` types themselves (never `SwiftUI`), and mutation functions never
/// call `modelContext.save()` — the caller (`TransactionImportService`) owns persistence.
enum TransactionDedupMatcher {
    /// Finds an existing manual (`entryMethod == .manual`) transaction that plausibly
    /// represents the same real-world purchase as `incoming`: same calendar day (per
    /// `calendar`, matching the app's existing day-boundary convention), same amount
    /// (exact — no tolerance), same merchant (case-insensitive exact match, consistent
    /// with `MerchantMatcher`'s semantics — no fuzzy/substring matching per
    /// PROJECT_SPEC.md's "Merchant matching" rule).
    ///
    /// Returns the first match found in `existingManualTransactions`; callers are
    /// expected to have already filtered that array to `.manual` entries (kept as a
    /// caller responsibility, not re-filtered here, so `TransactionImportService`'s one
    /// `FetchDescriptor` result can be reused across every incoming transaction in a
    /// sync page without this function re-deriving the manual subset each call).
    static func findMatch(
        for incoming: MappedPlaidTransaction,
        existingManualTransactions: [SpendTransaction],
        calendar: Calendar = .current
    ) -> SpendTransaction? {
        let incomingDay = calendar.startOfDay(for: incoming.date)
        return existingManualTransactions.first { candidate in
            candidate.entryMethod == .manual
                && candidate.amount == incoming.amount
                && calendar.startOfDay(for: candidate.date) == incomingDay
                && candidate.merchantName.caseInsensitiveCompare(incoming.merchantName) == .orderedSame
        }
    }

    /// Applies the "Merge" resolution: `manualTransaction` is updated in place so
    /// Plaid's data wins for `amount`/`date`/`merchantName` (the more likely accurate,
    /// normalized bank data), while `type`/`isManualOverride`/`savingsGoal` are left
    /// untouched — merging must never silently overwrite an explicit user choice or
    /// existing goal attribution. `entryMethod` becomes `.imported`, `plaidTransactionID`
    /// is set to the incoming transaction's ID, and `wasMergedFromManual` is set `true`
    /// so a later `removed` sync event reverts this row instead of hard-deleting it (see
    /// `SchemaV4`'s doc comment). The incoming Plaid transaction itself is never
    /// constructed as a separate row by this function — the caller simply discards it.
    static func applyMerge(to manualTransaction: SpendTransaction, incoming: MappedPlaidTransaction) {
        manualTransaction.amount = incoming.amount
        manualTransaction.date = incoming.date
        manualTransaction.merchantName = incoming.merchantName
        manualTransaction.entryMethod = .imported
        manualTransaction.plaidTransactionID = incoming.plaidTransactionID
        manualTransaction.wasMergedFromManual = true
    }
}
