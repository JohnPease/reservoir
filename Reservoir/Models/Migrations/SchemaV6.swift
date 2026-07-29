import Foundation
import SwiftData

/// Adds two fields for reservoir-loc.1's multi-item Plaid support:
///
/// - `SpendTransaction.plaidItemID: String?` — nil for manual entries, matching the
///   existing `plaidTransactionID` nil-for-manual convention. **Requires a custom
///   (non-lightweight) migration stage**, unlike every prior additive-optional-field
///   schema bump in this file's history: a plain `MigrationStage.lightweight` would
///   leave every *existing* imported row's `plaidItemID` as `nil`, which is wrong for any
///   user who already has one linked item — those rows really were imported from that
///   item, they just predate this column existing. `ReservoirMigrationPlan.migrateV5toV6`
///   backfills every row where `plaidTransactionID != nil` to the single item ID read
///   from the pre-migration `LinkedItemStore` (there is at most one linked item as of any
///   shipped build predating this story, so "the current item" is unambiguous at
///   migration time).
/// - `SavingsGoal.associatedItemIDs: [String] = []` — plain defaulted array. Lightweight/
///   inferred is correct here: this feature doesn't exist in any shipped version, so
///   every existing goal correctly defaults to zero associated accounts with no backfill
///   needed. Enforced to hold at most one goal per item ID by
///   `GoalAccountAssociationService`, not by any SwiftData-level constraint.
///
/// Both fields land in this one schema version rather than being split across two, since
/// neither depends on the other and splitting would only add an extra migration stage
/// with no benefit.
enum SchemaV6: VersionedSchema {
    static let versionIdentifier = Schema.Version(6, 0, 0)

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
        /// see this file's doc comment.
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
    @Model
    final class PendingTransactionMerge {
        @Attribute(.unique) var plaidTransactionID: String
        var incomingAmount: Decimal
        var incomingDate: Date
        var incomingMerchantName: String
        var manualTransaction: SpendTransaction?

        init(
            plaidTransactionID: String,
            incomingAmount: Decimal,
            incomingDate: Date,
            incomingMerchantName: String,
            manualTransaction: SpendTransaction?
        ) {
            self.plaidTransactionID = plaidTransactionID
            self.incomingAmount = incomingAmount
            self.incomingDate = incomingDate
            self.incomingMerchantName = incomingMerchantName
            self.manualTransaction = manualTransaction
        }
    }
}
