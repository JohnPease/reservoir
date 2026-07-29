import SwiftData

enum ReservoirMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [SchemaV1.self, SchemaV2.self, SchemaV3.self, SchemaV4.self, SchemaV5.self, SchemaV6.self, SchemaV7.self]
    }

    static var stages: [MigrationStage] {
        [migrateV1toV2, migrateV2toV3, migrateV3toV4, migrateV4toV5, migrateV5toV6, migrateV6toV7]
    }

    /// Lightweight (inferred) migration: `SavingsGoal.dismissedAt` and
    /// `SpendTransaction.createdAt` are both new, optional/defaulted fields with no
    /// renames or type changes, so SwiftData can infer the mapping without a custom
    /// willMigrate/didMigrate block.
    static let migrateV1toV2 = MigrationStage.lightweight(
        fromVersion: SchemaV1.self,
        toVersion: SchemaV2.self
    )

    /// Lightweight (inferred) migration: `SavingsGoal.createdAt` is a new, defaulted
    /// (`= .now`) field with no renames or type changes — see `SchemaV3`'s doc comment
    /// for the flagged, accepted consequence of backfilling pre-existing goals'
    /// `createdAt` to the migration run's timestamp.
    static let migrateV2toV3 = MigrationStage.lightweight(
        fromVersion: SchemaV2.self,
        toVersion: SchemaV3.self
    )

    /// Lightweight (inferred) migration: `SpendTransaction.wasMergedFromManual` is a
    /// new, defaulted (`= false`) field with no renames or type changes — see
    /// `SchemaV4`'s doc comment for what it's used for.
    static let migrateV3toV4 = MigrationStage.lightweight(
        fromVersion: SchemaV3.self,
        toVersion: SchemaV4.self
    )

    /// Lightweight (inferred) migration: `PendingTransactionMerge` is a wholly new
    /// `@Model` type with no renames or type changes to any existing model, so SwiftData
    /// can infer the mapping without a custom willMigrate/didMigrate block — see
    /// `SchemaV5`'s doc comment for what it's used for.
    static let migrateV4toV5 = MigrationStage.lightweight(
        fromVersion: SchemaV4.self,
        toVersion: SchemaV5.self
    )

    /// **Custom** migration (reservoir-loc.1) — not lightweight, unlike every stage
    /// above. `SavingsGoal.associatedItemIDs` is a plain defaulted (`= []`) new field
    /// with no renames/type changes, so it needs no special handling; but
    /// `SpendTransaction.plaidItemID` needs every *existing* imported row
    /// (`plaidTransactionID != nil`) backfilled to the current single linked item's ID —
    /// a plain lightweight/inferred migration would leave those rows' `plaidItemID` at
    /// `nil`, which is wrong (they really were imported from that item, they just
    /// predate this column). See `SchemaV6`'s doc comment.
    ///
    /// `willMigrate` reads `LinkedItemStore`'s pre-migration value (a plain UserDefaults-
    /// backed struct store, entirely independent of the SwiftData container being
    /// migrated here) and captures it in `capturedItemID`, a local variable both closures
    /// share by capture. `didMigrate` then runs against the post-migration `SchemaV6`
    /// container, where `plaidItemID` exists to write to. Deliberately split across both
    /// closures rather than reading `LinkedItemStore` directly inside `didMigrate` alone —
    /// this keeps "what pre-migration state fed the backfill" explicit and named, in case
    /// a future schema bump needs the same "read old-world state, apply to new-world
    /// model" shape and wants a template to follow.
    static let migrateV5toV6: MigrationStage = {
        var capturedItemID: String?
        return MigrationStage.custom(
            fromVersion: SchemaV5.self,
            toVersion: SchemaV6.self,
            willMigrate: { _ in
                capturedItemID = LinkedItemStore().loadAll().first?.itemID
            },
            didMigrate: { context in
                guard let itemID = capturedItemID else { return }
                // Filters in Swift rather than via a `#Predicate` on `plaidTransactionID
                // != nil` — same convention `TransactionImportService.fetchAllTransactions()`
                // documents: this app's transaction volume is personal-scale, and existing
                // `#Predicate` usage in this codebase only ever predicates on plain
                // non-optional `String` properties, not an optional-comparison field like
                // this one.
                let allRows = try context.fetch(FetchDescriptor<SchemaV6.SpendTransaction>())
                let importedRows = allRows.filter { $0.plaidTransactionID != nil }
                for row in importedRows {
                    row.plaidItemID = itemID
                }
                try context.save()
            }
        )
    }()

    /// Lightweight (inferred) migration: `PendingTransactionMerge.plaidItemID` is a new,
    /// defaulted-nil (`String?`) field with no renames or type changes to any existing
    /// model — see `SchemaV7`'s doc comment for why no backfill (unlike `SchemaV6`'s
    /// custom `migrateV5toV6` stage) is needed here.
    static let migrateV6toV7 = MigrationStage.lightweight(
        fromVersion: SchemaV6.self,
        toVersion: SchemaV7.self
    )
}
