import Foundation
import SwiftData

/// Adds `SpendTransaction.wasMergedFromManual` for the transaction import story
/// (adq.6.3). Non-optional, defaulted to `false` at both the property and `init`
/// level — a genuinely new field with no renames or type changes, so V3 -> V4 is a
/// lightweight (inferred) migration, same discipline as `SchemaV3`'s
/// `SavingsGoal.createdAt` addition.
///
/// Distinguishes a *pure import* (`entryMethod` became `.imported` only via a Plaid
/// fetch, never touched by a manual entry) from a *merge-derived* row (a manual entry
/// the user chose to "Merge" with a matching Plaid transaction — `entryMethod` becomes
/// `.imported`, but the row's identity is still the user's original manual entry).
/// Both look identical under the V3 schema (`entryMethod == .imported`,
/// `plaidTransactionID` set) even though they must be handled differently when Plaid's
/// `/transactions/sync` later reports the same transaction as `removed`: a pure import
/// is safe to hard-delete, but a merge-derived row must be reverted to `.manual`
/// instead (deleting it would destroy data the user entered themselves) — see
/// `TransactionImportService`'s `removed` handling.
///
/// Set `true` only by `TransactionDedupMatcher.applyMerge(to:incoming:)` (the "Merge"
/// resolution path); every other write path (fresh import, "Keep both", `modified`
/// upsert) leaves it at its default `false`.
enum SchemaV4: VersionedSchema {
    static let versionIdentifier = Schema.Version(4, 0, 0)

    static var models: [any PersistentModel.Type] {
        [SavingsGoal.self, SpendTransaction.self, MerchantRule.self]
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
        /// Plaid-imported transaction (adq.6.3) — see this file's doc comment for the
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
}
