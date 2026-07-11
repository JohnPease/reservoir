import XCTest
import SwiftData
@testable import Reservoir

/// Regression coverage for review finding 1: a store created under `SchemaV1` (as any
/// pre-adq.2 build would have on disk) must open cleanly under `SchemaV2` via
/// `ReservoirMigrationPlan`, with existing data intact and the new `dismissedAt`/
/// `createdAt` fields present with their defaults — not fail to load and fall into
/// `ReservoirApp`'s corrupted-store fallback, which deletes the store outright.
final class MigrationPlanTests: XCTestCase {
    private var storeURL: URL!

    override func setUpWithError() throws {
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MigrationPlanTests-\(UUID().uuidString)")
            .appendingPathExtension("store")
    }

    override func tearDownWithError() throws {
        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + suffix))
        }
        storeURL = nil
    }

    func testV1StoreMigratesToV2WithDataIntact() throws {
        // Simulate a pre-adq.2 on-disk store: create it against SchemaV1 alone, with no
        // knowledge of SchemaV2's fields.
        let v1Schema = Schema(versionedSchema: SchemaV1.self)
        let v1Configuration = ModelConfiguration(schema: v1Schema, url: storeURL)
        do {
            let v1Container = try ModelContainer(for: v1Schema, configurations: [v1Configuration])
            let context = ModelContext(v1Container)
            let goal = SchemaV1.SavingsGoal(
                targetAmount: 1000,
                targetDate: Calendar.current.date(byAdding: .day, value: 30, to: .now)!,
                startDate: .now,
                startingBalance: 100,
                dailyBase: 30
            )
            context.insert(goal)
            try context.save()
        }

        // Now open the same store URL under SchemaV2 via the real migration plan, as
        // ReservoirApp.makeModelContainer does.
        let v2Schema = Schema(versionedSchema: SchemaV2.self)
        let v2Configuration = ModelConfiguration(schema: v2Schema, url: storeURL)
        let v2Container = try ModelContainer(
            for: v2Schema,
            migrationPlan: ReservoirMigrationPlan.self,
            configurations: [v2Configuration]
        )
        let context = ModelContext(v2Container)
        // Explicitly `SchemaV2.SavingsGoal`, not the bare `SavingsGoal` alias — that alias
        // now points at `SchemaV3` (see `CurrentSchema.swift`), and this container was
        // opened `for: v2Schema` only, so a `SchemaV3`-typed `FetchDescriptor` doesn't
        // relate to it.
        let fetched = try context.fetch(FetchDescriptor<SchemaV2.SavingsGoal>())

        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.targetAmount, 1000)
        XCTAssertEqual(fetched.first?.dailyBase, 30)
        // The new field defaults to nil for data that predates it.
        XCTAssertNil(fetched.first?.dismissedAt)
    }

    /// Regression coverage for adq.5: a store created under `SchemaV2` (as any
    /// pre-adq.5 build would have on disk) must open cleanly under `SchemaV3` via
    /// `ReservoirMigrationPlan`, with existing data intact and the new `createdAt` field
    /// present, backfilled to (approximately) the migration run's timestamp — the
    /// flagged, accepted consequence documented in `SchemaV3`.
    func testV2StoreMigratesToV3WithDataIntactAndCreatedAtBackfilled() throws {
        // A few seconds' slack, not a strict `beforeMigration`/`afterMigration` bracket —
        // SQLite's underlying Date storage loses sub-second precision, which can put the
        // backfilled `createdAt` a hair before a `Date()` captured immediately prior.
        let beforeMigration = Date().addingTimeInterval(-5)

        let v2Schema = Schema(versionedSchema: SchemaV2.self)
        let v2Configuration = ModelConfiguration(schema: v2Schema, url: storeURL)
        do {
            let v2Container = try ModelContainer(for: v2Schema, configurations: [v2Configuration])
            let context = ModelContext(v2Container)
            let goal = SchemaV2.SavingsGoal(
                targetAmount: 500,
                targetDate: Calendar.current.date(byAdding: .day, value: 30, to: .now)!,
                startDate: Calendar.current.date(byAdding: .day, value: -30, to: .now)!,
                startingBalance: 50,
                dailyBase: 20
            )
            context.insert(goal)
            try context.save()
        }

        let v3Schema = Schema(versionedSchema: SchemaV3.self)
        let v3Configuration = ModelConfiguration(schema: v3Schema, url: storeURL)
        let v3Container = try ModelContainer(
            for: v3Schema,
            migrationPlan: ReservoirMigrationPlan.self,
            configurations: [v3Configuration]
        )
        let context = ModelContext(v3Container)
        let fetched = try context.fetch(FetchDescriptor<SavingsGoal>())
        let afterMigration = Date()

        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.targetAmount, 500)
        XCTAssertEqual(fetched.first?.dailyBase, 20)
        let createdAt = try XCTUnwrap(fetched.first?.createdAt)
        XCTAssertGreaterThanOrEqual(createdAt, beforeMigration)
        XCTAssertLessThanOrEqual(createdAt, afterMigration)
    }
}
