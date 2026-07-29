import Foundation
import SwiftData

/// Adds `PendingTransactionMerge.plaidItemID: String?` for reservoir-loc.2's multi-item
/// import loop.
///
/// Without this field, the "Keep both" merge resolution (`TransactionImportService
/// .applyKeepBothDecision`) had no durable way to recover which linked item the pending
/// decision's incoming transaction came from — `PendingTransactionMerge` (unlike
/// `SpendTransaction`, which gained `plaidItemID` in `SchemaV6`) predates per-item import
/// entirely. reservoir-loc.1 explicitly deferred this (see `SchemaV6`'s doc comment on
/// `TransactionImportService.buildNewImportedTransaction`'s `sourceItemID` parameter),
/// leaving every "Keep both" result's `plaidItemID` `nil` even after `SchemaV6` landed.
/// This story closes that gap: `processPage` now stamps the item ID it already has in
/// scope onto the record at construction time, and `applyKeepBothDecision` reads it back
/// off the persisted row to pass through to `buildNewImportedTransaction`.
///
/// Plain additive/optional field, no renames or type changes to any existing property —
/// **lightweight (inferred) migration is correct here**, unlike `SchemaV6`'s custom stage
/// for `SpendTransaction.plaidItemID`. That field needed a backfill because *existing*
/// imported rows genuinely were imported from a real (single, unambiguous) linked item
/// before the column existed. A pending `PendingTransactionMerge` row has no equivalent
/// backfill target: any row that survives from before this schema bump was queued back
/// when only one item could ever be linked, so its manual-transaction/incoming-Plaid-data
/// pairing is unaffected by leaving `plaidItemID` `nil` — nothing reads that field to
/// resolve behavior for a pre-existing row, and a fresh sync run naturally produces
/// correctly-stamped rows going forward. Same reasoning `SchemaV5`/`SchemaV4` used for
/// their own purely-additive bumps.
enum SchemaV7: VersionedSchema {
    static let versionIdentifier = Schema.Version(7, 0, 0)

    static var models: [any PersistentModel.Type] {
        [SavingsGoal.self, SpendTransaction.self, MerchantRule.self, PendingTransactionMerge.self]
    }

    enum TransactionType: String, Codable {
        case variable
        case fixed
    }

    enum EntryMethod: String, Codable {
        case manual
        case imported
    }

    @Model
    final class SavingsGoal {
        var targetAmount: Decimal
        var targetDate: Date
        var startDate: Date
        var startingBalance: Decimal
        var dailyBase: Decimal
        var lastEditedDate: Date?
        var dismissedAt: Date?
        var createdAt: Date = Date.now
        /// Linked-item IDs (`LinkedItem.itemID`) associated with this goal — at most one
        /// goal may reference a given item ID at a time, enforced by
        /// `GoalAccountAssociationService`, the single choke point for that invariant.
        /// Defaults to empty for every pre-existing goal (this feature is wholly new).
        var associatedItemIDs: [String] = []

        @Relationship(deleteRule: .nullify, inverse: \SpendTransaction.savingsGoal)
        var transactions: [SpendTransaction] = []

        init(
            targetAmount: Decimal,
            targetDate: Date,
            startDate: Date,
            startingBalance: Decimal,
            dailyBase: Decimal,
            lastEditedDate: Date? = nil,
            dismissedAt: Date? = nil,
            createdAt: Date = .now,
            associatedItemIDs: [String] = []
        ) {
            self.targetAmount = targetAmount
            self.targetDate = targetDate
            self.startDate = startDate
            self.startingBalance = startingBalance
            self.dailyBase = dailyBase
            self.lastEditedDate = lastEditedDate
            self.dismissedAt = dismissedAt
            self.createdAt = createdAt
            self.associatedItemIDs = associatedItemIDs
        }
    }

    /// Named `SpendTransaction`, not `Transaction` — SwiftUI already exports a
    /// `Transaction` type (animation transactions), and this module imports
    /// SwiftUI, so the bare name would be ambiguous at any call site using both.
    @Model
    final class SpendTransaction {
        var amount: Decimal
        var date: Date
        var merchantName: String
        var type: TransactionType
        var entryMethod: EntryMethod
        /// nil for manual entries; set for Plaid-imported transactions.
        @Attribute(.unique) var plaidTransactionID: String?
        /// The linked item (`LinkedItem.itemID`) this transaction was imported from —
        /// nil for manual entries, same nil-for-manual convention as
        /// `plaidTransactionID` (reservoir-loc.1). Existing imported rows are backfilled
        /// by `ReservoirMigrationPlan.migrateV5toV6`'s custom stage rather than left nil;
        /// see `SchemaV6`'s doc comment.
        var plaidItemID: String?
        /// True when a user explicitly set/changed `type` on this transaction.
        /// MerchantRule re-application must not overwrite a manual override.
        var isManualOverride: Bool
        /// When this record was created (distinct from `date`, the user-facing
        /// transaction date, which can be backdated/edited). Added for the Today screen
        /// story (adq.2) as the tiebreaker for "recent transactions, sorted by date then
        /// creation order" — `date` alone doesn't disambiguate same-day entries.
        var createdAt: Date
        /// True only for a manual entry the user chose to "Merge" with a matching
        /// Plaid-imported transaction (adq.6.3) — see `SchemaV4`'s doc comment for the
        /// pure-import-vs-merge-derived distinction this protects on a later `removed`
        /// sync event.
        var wasMergedFromManual: Bool = false

        var savingsGoal: SavingsGoal?

        init(
            amount: Decimal,
            date: Date,
            merchantName: String,
            type: TransactionType,
            entryMethod: EntryMethod,
            plaidTransactionID: String? = nil,
            plaidItemID: String? = nil,
            isManualOverride: Bool = false,
            savingsGoal: SavingsGoal? = nil,
            createdAt: Date = .now,
            wasMergedFromManual: Bool = false
        ) {
            self.amount = amount
            self.date = date
            self.merchantName = merchantName
            self.type = type
            self.entryMethod = entryMethod
            self.plaidTransactionID = plaidTransactionID
            self.plaidItemID = plaidItemID
            self.isManualOverride = isManualOverride
            self.savingsGoal = savingsGoal
            self.createdAt = createdAt
            self.wasMergedFromManual = wasMergedFromManual
        }
    }

    @Model
    final class MerchantRule {
        /// Matched exact, case-insensitive against SpendTransaction.merchantName.
        var merchantName: String
        var type: TransactionType

        init(merchantName: String, type: TransactionType) {
            self.merchantName = merchantName
            self.type = type
        }
    }

    /// Durable form of `TransactionImportService.PendingMergeDecision` — see `SchemaV5`'s
    /// doc comment for why this needs to survive process death. `incoming*` fields are a
    /// flat snapshot of a `MappedPlaidTransaction` (a plain value type with no SwiftData
    /// dependency by design — see that type's doc comment — so it can't be stored
    /// directly as a `@Model` relationship). `manualTransaction` is optional only because
    /// SwiftData relationships are always optional-at-rest; a row whose
    /// `manualTransaction` has been deleted out from under it (not expected in normal
    /// flow, no manual-transaction-deletion UI exists during an unresolved merge prompt)
    /// is treated as orphaned and dropped by
    /// `TransactionImportService.hydrateMergeQueue()`.
    ///
    /// `plaidItemID` (reservoir-loc.2, this file) — the linked item the incoming Plaid
    /// transaction came from; nil only for rows that predate this field (see this file's
    /// doc comment for why no backfill is needed). Stamped at construction time in
    /// `TransactionImportService.processPage`, read back by `applyKeepBothDecision` so a
    /// "Keep both" resolution correctly attributes its new row to the right account's
    /// goal.
    @Model
    final class PendingTransactionMerge {
        @Attribute(.unique) var plaidTransactionID: String
        var incomingAmount: Decimal
        var incomingDate: Date
        var incomingMerchantName: String
        var manualTransaction: SpendTransaction?
        var plaidItemID: String?

        init(
            plaidTransactionID: String,
            incomingAmount: Decimal,
            incomingDate: Date,
            incomingMerchantName: String,
            manualTransaction: SpendTransaction?,
            plaidItemID: String? = nil
        ) {
            self.plaidTransactionID = plaidTransactionID
            self.incomingAmount = incomingAmount
            self.incomingDate = incomingDate
            self.incomingMerchantName = incomingMerchantName
            self.manualTransaction = manualTransaction
            self.plaidItemID = plaidItemID
        }
    }
}
