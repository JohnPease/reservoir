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
        let fetched = try context.fetch(FetchDescriptor<SavingsGoal>())

        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.targetAmount, 1000)
        XCTAssertEqual(fetched.first?.dailyBase, 30)
        // The new field defaults to nil for data that predates it.
        XCTAssertNil(fetched.first?.dismissedAt)
    }
}
