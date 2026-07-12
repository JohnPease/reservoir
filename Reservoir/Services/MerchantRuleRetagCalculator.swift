import Foundation
import SwiftData

/// Pure logic backing the retroactive retag pass (adq.3, JP decision 2026-07-07): when a
/// `MerchantRule` is created, or edited such that its `merchantName` or `type` changes,
/// every existing `SpendTransaction` whose `merchantName` case-insensitively matches the
/// rule's (new) `merchantName` and whose `isManualOverride == false` gets its `type` set
/// to the rule's `type`. `isManualOverride == true` transactions are never touched — that
/// flag exists specifically to protect an explicit user choice from a later rule change.
///
/// Kept out of `MerchantRuleEntryView` per STANDARDS.md §3/§4 so both the "does this edit
/// even need to fire a retag" diff and the "which transactions match" selection are
/// independently unit-testable without driving SwiftUI. `applyRetag` performs the actual
/// in-memory mutation (no `modelContext.save()` here) so the call site can combine rule
/// mutation + transaction retagging into one atomic save (adq.3 kickoff check 2).
enum MerchantRuleRetagCalculator {
    /// Whether an edit from `(oldMerchantName, oldType)` to `(newMerchantName, newType)`
    /// should fire the retag pass at all. A no-op edit — same merchant name
    /// (case-insensitive) and same type — must not refire it (adq.3 kickoff check 3), so a
    /// rule can be opened and saved unchanged without redundantly re-touching every
    /// matching transaction's `type` (harmless in isolation, but avoided to keep the
    /// retag pass's trigger condition exact and testable on its own).
    static func requiresRetag(
        oldMerchantName: String,
        oldType: TransactionType,
        newMerchantName: String,
        newType: TransactionType
    ) -> Bool {
        let namesMatch = oldMerchantName.caseInsensitiveCompare(newMerchantName) == .orderedSame
        return !(namesMatch && oldType == newType)
    }

    /// The subset of `transactions` that a rule for `merchantName` should retag: a
    /// case-insensitive `merchantName` match, excluding anything with
    /// `isManualOverride == true`.
    static func transactionsToRetag(
        _ transactions: [SpendTransaction],
        merchantName: String
    ) -> [SpendTransaction] {
        transactions.filter { transaction in
            !transaction.isManualOverride
                && transaction.merchantName.caseInsensitiveCompare(merchantName) == .orderedSame
        }
    }

    /// Mutates each of `transactions` in place, setting `type` to `newType`. Pure
    /// in-memory mutation only — no persistence call — so the caller can fold this
    /// together with the rule's own create/edit mutation into a single
    /// `modelContext.save()`.
    static func applyRetag(to transactions: [SpendTransaction], newType: TransactionType) {
        for transaction in transactions {
            transaction.type = newType
        }
    }
}
