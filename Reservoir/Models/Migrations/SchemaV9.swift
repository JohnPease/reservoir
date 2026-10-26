import Foundation
import SwiftData

/// Adds the `Budget` model (reservoir-j8t PR2) — the one app-wide monthly budget, tracked
/// independently of savings goals.
///
/// A wholly new `@Model` type with no renames or type changes to any existing model, so
/// **lightweight (inferred) migration is correct**; existing stores simply gain an empty
/// `Budget` table. `Budget` has no relationship to `SpendTransaction`: which transactions
/// count toward it is derived from `selectedAccountIDs` against each transaction's
/// `plaidAccountID` (see `BudgetCalculator`), so a transaction can count toward a budget
/// and a savings goal independently. "Only one budget" is enforced in `BudgetService`, not
/// by the schema.
enum SchemaV9: VersionedSchema {
    static let versionIdentifier = Schema.Version(9, 0, 0)

    static var models: [any PersistentModel.Type] {
        [SavingsGoal.self, SpendTransaction.self, MerchantRule.self, PendingTransactionMerge.self, Budget.self]
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
        /// The Plaid account (`PlaidAccount.account_id`) this transaction belongs to —
        /// nil for manual entries and for imported rows not yet stamped by the one-time
        /// account backfill (reservoir-j8t). Never overwritten once non-nil.
        var plaidAccountID: String?
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
            plaidAccountID: String? = nil,
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
            self.plaidAccountID = plaidAccountID
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
        /// The Plaid account the incoming transaction came from (reservoir-j8t); read
        /// back by `applyKeepBothDecision`. nil for rows that predate `SchemaV8`.
        var plaidAccountID: String?

        init(
            plaidTransactionID: String,
            incomingAmount: Decimal,
            incomingDate: Date,
            incomingMerchantName: String,
            manualTransaction: SpendTransaction?,
            plaidItemID: String? = nil,
            plaidAccountID: String? = nil
        ) {
            self.plaidTransactionID = plaidTransactionID
            self.incomingAmount = incomingAmount
            self.incomingDate = incomingDate
            self.incomingMerchantName = incomingMerchantName
            self.manualTransaction = manualTransaction
            self.plaidItemID = plaidItemID
            self.plaidAccountID = plaidAccountID
        }
    }

    /// The single app-wide monthly budget. No revision history: the calculator recomputes
    /// the entire window from `startDate` with whatever these fields currently say.
    @Model
    final class Budget {
        var monthlyAmount: Decimal
        /// First day spending is counted from (day granularity).
        var startDate: Date
        /// true = "Carry over" (surplus and debt roll across months); false = "Start fresh"
        /// (carry is zeroed on every 1st).
        var carriesAcrossMonths: Bool = true
        /// Plaid account IDs (`LinkedAccount.accountID`) whose transactions count.
        var selectedAccountIDs: [String] = []
        var createdAt: Date = Date.now

        init(
            monthlyAmount: Decimal,
            startDate: Date,
            carriesAcrossMonths: Bool = true,
            selectedAccountIDs: [String] = [],
            createdAt: Date = .now
        ) {
            self.monthlyAmount = monthlyAmount
            self.startDate = startDate
            self.carriesAcrossMonths = carriesAcrossMonths
            self.selectedAccountIDs = selectedAccountIDs
            self.createdAt = createdAt
        }
    }
}
