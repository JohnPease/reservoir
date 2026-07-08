import Foundation
import SwiftData

/// Adds `SavingsGoal.dismissedAt` and `SpendTransaction.createdAt` for the Today screen
/// story (adq.2). Both fields are optional/defaulted, so the V1 -> V2 migration is a
/// lightweight (inferred) stage — see `ReservoirMigrationPlan`. Bumping the schema
/// version (rather than adding these fields directly to `SchemaV1`) is required: any
/// store already created from a pre-adq.2 build was validated against V1's shape at
/// `Schema.Version(1, 0, 0)`, and `ModelContainer(for:migrationPlan:)` would otherwise
/// treat that on-disk store as version-1-but-shape-mismatched and fail to open it.
enum SchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)

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
        /// Fixed at creation/edit — see docs/PROJECT_SPEC.md "Core mechanic".
        /// Computed by the daily-limit calculator, not by this model.
        var dailyBase: Decimal
        /// Date of the most recent edit to `targetAmount`/`targetDate` (nil if never
        /// edited since creation). Maps to `DailyLimitCalculator.GoalCarryForwardInput
        /// .effectiveStartDate` as `lastEditedDate ?? startDate` — an edit resets where
        /// carry-forward starts accumulating from, per PROJECT_SPEC "Core mechanic".
        var lastEditedDate: Date?
        /// Set when the user dismisses the Today screen's completion banner after
        /// `targetDate` has passed. A goal is "active" only while this is nil — see
        /// `TodayScreenCalculator.isActive`. Added for the Today screen story (adq.2):
        /// completion can't be derived from `targetDate` alone because the banner must
        /// keep showing (undismissed) across app launches until the user acts on it,
        /// then never show again once they have.
        var dismissedAt: Date?

        @Relationship(deleteRule: .nullify, inverse: \SpendTransaction.savingsGoal)
        var transactions: [SpendTransaction] = []

        init(
            targetAmount: Decimal,
            targetDate: Date,
            startDate: Date,
            startingBalance: Decimal,
            dailyBase: Decimal,
            lastEditedDate: Date? = nil,
            dismissedAt: Date? = nil
        ) {
            self.targetAmount = targetAmount
            self.targetDate = targetDate
            self.startDate = startDate
            self.startingBalance = startingBalance
            self.dailyBase = dailyBase
            self.lastEditedDate = lastEditedDate
            self.dismissedAt = dismissedAt
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
            createdAt: Date = .now
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
