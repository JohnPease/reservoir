import Foundation
import SwiftData

/// Adds `PendingTransactionMerge` for the transaction import story (adq.6.3), so a
/// queued merge-prompt decision (Plaid reported an incoming transaction that dedup-
/// matched an existing manual entry, and the user hasn't yet chosen "Merge" or "Keep
/// both") is durably persisted rather than living only in
/// `TransactionImportService.mergeQueue`'s in-memory array.
///
/// Before this schema, a pending decision was lost if the app was killed or the
/// `TransactionImportService` instance was deallocated before the user resolved it —
/// Plaid won't redeliver an already-acknowledged `added` item once the sync cursor
/// (persisted separately, in `PlaidSyncCursorStore`) moves past its page, and the
/// cursor *does* advance past a page whose only unhandled item was merely queued (see
/// `TransactionImportService.runImport()`'s doc comment) — so an unpersisted queue
/// entry was gone for good, silently, with no way to recover the transaction. A
/// SwiftData-backed row survives process death and is re-hydrated into
/// `mergeQueue` on the next `TransactionImportService` construction (app relaunch),
/// and doubles as the source of truth for "is there already a pending decision for
/// this manual transaction" — `TransactionImportService` excludes any manual
/// transaction already referenced by a persisted `PendingTransactionMerge` row from
/// the dedup-match candidate pool at the start of every `runImport()`, so a second,
/// independent sync run can't queue a duplicate decision against the same manual row.
///
/// New `@Model` type only, no changes to existing models — a purely additive,
/// lightweight (inferred) migration, same discipline as `SchemaV4`'s addition of
/// `SpendTransaction.wasMergedFromManual`.
enum SchemaV5: VersionedSchema {
    static let versionIdentifier = Schema.Version(5, 0, 0)

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
            createdAt: Date = .now
        ) {
            self.targetAmount = targetAmount
            self.targetDate = targetDate
            self.startDate = startDate
            self.startingBalance = startingBalance
            self.dailyBase = dailyBase
            self.lastEditedDate = lastEditedDate
            self.dismissedAt = dismissedAt
            self.createdAt = createdAt
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

    /// Durable form of `TransactionImportService.PendingMergeDecision` — see this file's
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
