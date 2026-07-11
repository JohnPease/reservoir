import Foundation
import SwiftData

/// Adds `SavingsGoal.createdAt` for the Goals screen story (adq.5). Non-optional,
/// defaulted to `.now` at init — a genuine, real creation timestamp, distinct from the
/// user-facing, backdatable `startDate`. Existing/new fields are all optional or
/// defaulted with no renames or type changes, so the V2 -> V3 migration is a lightweight
/// (inferred) stage — see `ReservoirMigrationPlan`. As with V1 -> V2, bumping the schema
/// version (rather than editing `SchemaV2` in place) is required so a store already
/// created from a pre-adq.5 build isn't validated against a shape it wasn't written with.
///
/// `createdAt` is the floor `TodayScreenCalculator`/`GoalsScreenCalculator`'s
/// `effectiveStartDate` mapping uses so a backdated `startDate` can't accrue
/// carry-forward for days before the goal actually existed in the app — see
/// `TodayScreenCalculator.carryForwardInput(for:)`. Any goal that exists before this
/// migration lands gets `createdAt` backfilled to the migration run's timestamp, which —
/// under `effectiveStartDate = lastEditedDate ?? max(startDate, createdAt)` — retroactively
/// zeroes that goal's carry-forward history the moment the app updates. Acceptable,
/// flagged explicitly: this is pre-release/personal use with no installed base to protect.
enum SchemaV3: VersionedSchema {
    static let versionIdentifier = Schema.Version(3, 0, 0)

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
        /// .effectiveStartDate` as `lastEditedDate ?? max(startDate, createdAt)` — an edit
        /// resets where carry-forward starts accumulating from, per PROJECT_SPEC "Core
        /// mechanic".
        var lastEditedDate: Date?
        /// Set when the user dismisses the Today screen's completion banner after
        /// `targetDate` has passed. A goal is "active" only while this is nil — see
        /// `TodayScreenCalculator.isActive`. Added for the Today screen story (adq.2):
        /// completion can't be derived from `targetDate` alone because the banner must
        /// keep showing (undismissed) across app launches until the user acts on it,
        /// then never show again once they have.
        var dismissedAt: Date?
        /// When this goal was actually created in the app — set once at init, never
        /// user-editable, never mutated. Added for the Goals screen story (adq.5) as the
        /// carry-forward accrual floor: `startDate` is now user-backdatable (see
        /// `GoalFormValidator`), but days before the goal's real `createdAt` never had an
        /// attributable transaction (there's no retroactive-attribution UI), so crediting
        /// them a full `dailyBase` of carry-forward would fabricate banked surplus from
        /// nothing. See `TodayScreenCalculator.carryForwardInput(for:)`.
        ///
        /// The `= .now` default is declared directly on the stored property (not just as
        /// an `init` parameter default) — SwiftData's lightweight/inferred migration
        /// needs the property-level default to backfill this new *non-optional* attribute
        /// for existing rows; an `init`-only default has no effect on migration, only on
        /// newly constructed Swift objects.
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
