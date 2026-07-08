import SwiftData

enum ReservoirMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [SchemaV1.self, SchemaV2.self]
    }

    static var stages: [MigrationStage] {
        [migrateV1toV2]
    }

    /// Lightweight (inferred) migration: `SavingsGoal.dismissedAt` and
    /// `SpendTransaction.createdAt` are both new, optional/defaulted fields with no
    /// renames or type changes, so SwiftData can infer the mapping without a custom
    /// willMigrate/didMigrate block.
    static let migrateV1toV2 = MigrationStage.lightweight(
        fromVersion: SchemaV1.self,
        toVersion: SchemaV2.self
    )
}
