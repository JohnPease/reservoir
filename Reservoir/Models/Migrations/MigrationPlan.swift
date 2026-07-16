import SwiftData

enum ReservoirMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [SchemaV1.self, SchemaV2.self, SchemaV3.self, SchemaV4.self]
    }

    static var stages: [MigrationStage] {
        [migrateV1toV2, migrateV2toV3, migrateV3toV4]
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
}
