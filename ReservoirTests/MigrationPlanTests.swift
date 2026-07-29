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
        // Explicitly `SchemaV3.SavingsGoal`, not the bare `SavingsGoal` alias — that
        // alias now points at `SchemaV4` (see `CurrentSchema.swift`), and this container
        // was opened `for: v3Schema` only, so a `SchemaV4`-typed `FetchDescriptor`
        // doesn't relate to it (same pitfall the V1->V2 test above already documents;
        // this one crashed with a real "KeyPath does not relate" fatal error before this
        // fix, once `CurrentSchema`'s aliases moved to `SchemaV4` for adq.6.3).
        let fetched = try context.fetch(FetchDescriptor<SchemaV3.SavingsGoal>())
        let afterMigration = Date()

        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.targetAmount, 500)
        XCTAssertEqual(fetched.first?.dailyBase, 20)
        let createdAt = try XCTUnwrap(fetched.first?.createdAt)
        XCTAssertGreaterThanOrEqual(createdAt, beforeMigration)
        XCTAssertLessThanOrEqual(createdAt, afterMigration)
    }

    /// Regression coverage for adq.6.3: a store created under `SchemaV3` (as any
    /// pre-adq.6.3 build would have on disk) must open cleanly under `SchemaV4` via
    /// `ReservoirMigrationPlan`, with existing data intact and the new
    /// `wasMergedFromManual` field present, defaulted to `false` for data that predates
    /// it — see `SchemaV4`'s doc comment.
    func testV3StoreMigratesToV4WithDataIntactAndWasMergedFromManualDefaultedFalse() throws {
        let v3Schema = Schema(versionedSchema: SchemaV3.self)
        let v3Configuration = ModelConfiguration(schema: v3Schema, url: storeURL)
        do {
            let v3Container = try ModelContainer(for: v3Schema, configurations: [v3Configuration])
            let context = ModelContext(v3Container)
            let transaction = SchemaV3.SpendTransaction(
                amount: 45.00,
                date: .now,
                merchantName: "Grocery Store",
                type: .variable,
                entryMethod: .imported,
                plaidTransactionID: "plaid-txn-existing"
            )
            context.insert(transaction)
            try context.save()
        }

        let v4Schema = Schema(versionedSchema: SchemaV4.self)
        let v4Configuration = ModelConfiguration(schema: v4Schema, url: storeURL)
        let v4Container = try ModelContainer(
            for: v4Schema,
            migrationPlan: ReservoirMigrationPlan.self,
            configurations: [v4Configuration]
        )
        let context = ModelContext(v4Container)
        // Explicitly `SchemaV4.SpendTransaction`, not the bare `SpendTransaction` alias —
        // that alias now points at `SchemaV5` (see `CurrentSchema.swift`), and this
        // container was opened `for: v4Schema` only (same pitfall the V1->V2 and
        // V2->V3 tests above already document).
        let fetched = try context.fetch(FetchDescriptor<SchemaV4.SpendTransaction>())

        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.merchantName, "Grocery Store")
        XCTAssertEqual(fetched.first?.plaidTransactionID, "plaid-txn-existing")
        XCTAssertEqual(fetched.first?.wasMergedFromManual, false)
    }

    /// Regression coverage for review findings 2+5 (adq.6.3): a store created under
    /// `SchemaV4` (as any pre-fix build would have on disk) must open cleanly under
    /// `SchemaV5` via `ReservoirMigrationPlan`, with existing data intact and the new
    /// `PendingTransactionMerge` model usable — see `SchemaV5`'s doc comment.
    func testV4StoreMigratesToV5WithDataIntactAndPendingTransactionMergeUsable() throws {
        let v4Schema = Schema(versionedSchema: SchemaV4.self)
        let v4Configuration = ModelConfiguration(schema: v4Schema, url: storeURL)
        do {
            let v4Container = try ModelContainer(for: v4Schema, configurations: [v4Configuration])
            let context = ModelContext(v4Container)
            let transaction = SchemaV4.SpendTransaction(
                amount: 30.00,
                date: .now,
                merchantName: "Hardware Store",
                type: .variable,
                entryMethod: .manual
            )
            context.insert(transaction)
            try context.save()
        }

        let v5Schema = Schema(versionedSchema: SchemaV5.self)
        let v5Configuration = ModelConfiguration(schema: v5Schema, url: storeURL)
        let v5Container = try ModelContainer(
            for: v5Schema,
            migrationPlan: ReservoirMigrationPlan.self,
            configurations: [v5Configuration]
        )
        let context = ModelContext(v5Container)
        // Explicitly `SchemaV5.SpendTransaction`/`SchemaV5.PendingTransactionMerge`, not
        // the bare aliases — those now point at `SchemaV6` (see `CurrentSchema.swift`),
        // and this container was opened `for: v5Schema` only (same pitfall the V1->V2/
        // V2->V3/V3->V4 tests above already document).
        let fetchedTransactions = try context.fetch(FetchDescriptor<SchemaV5.SpendTransaction>())

        XCTAssertEqual(fetchedTransactions.count, 1)
        XCTAssertEqual(fetchedTransactions.first?.merchantName, "Hardware Store")

        // The new model is usable post-migration: insert and fetch a
        // PendingTransactionMerge referencing the migrated transaction.
        let manual = try XCTUnwrap(fetchedTransactions.first)
        let pending = SchemaV5.PendingTransactionMerge(
            plaidTransactionID: "plaid-new",
            incomingAmount: 30.00,
            incomingDate: .now,
            incomingMerchantName: "Hardware Store",
            manualTransaction: manual
        )
        context.insert(pending)
        try context.save()

        let fetchedPending = try context.fetch(FetchDescriptor<SchemaV5.PendingTransactionMerge>())
        XCTAssertEqual(fetchedPending.count, 1)
        XCTAssertEqual(fetchedPending.first?.manualTransaction?.persistentModelID, manual.persistentModelID)
    }

    /// Regression coverage for reservoir-loc.1: a store created under `SchemaV5` (as any
    /// pre-loc.1 build would have on disk) must open cleanly under `SchemaV6` via
    /// `ReservoirMigrationPlan`, with existing data intact, `SavingsGoal.associatedItemIDs`
    /// lightweight-defaulted to `[]`, and — the part a plain lightweight/inferred
    /// migration would get wrong — every *existing imported* `SpendTransaction` row's new
    /// `plaidItemID` backfilled to the single item ID that was linked pre-migration (read
    /// from `LinkedItemStore`), not left `nil`. A manual entry must stay `nil`, matching
    /// the existing `plaidTransactionID` nil-for-manual convention. See `SchemaV6`'s and
    /// `ReservoirMigrationPlan.migrateV5toV6`'s doc comments.
    func testV5StoreMigratesToV6WithPlaidItemIDBackfilledAndAssociatedItemIDsDefaulted() throws {
        // `ReservoirMigrationPlan.migrateV5toV6`'s `willMigrate` reads the pre-migration
        // linked item via `LinkedItemStore()`'s default (real `UserDefaults.standard`)
        // init — snapshot and restore whatever's really there so this test can't leak
        // state into (or be polluted by) any other test in the same process.
        let linkedItemStore = LinkedItemStore()
        let preExistingItems = linkedItemStore.loadAll()
        for item in preExistingItems { linkedItemStore.remove(itemID: item.itemID) }
        addTeardownBlock {
            linkedItemStore.remove(itemID: "existing-item-1")
            for item in preExistingItems { linkedItemStore.save(item) }
        }
        linkedItemStore.save(LinkedItem(itemID: "existing-item-1", institutionName: "Existing Bank", linkedAt: .now))

        let v5Schema = Schema(versionedSchema: SchemaV5.self)
        let v5Configuration = ModelConfiguration(schema: v5Schema, url: storeURL)
        do {
            let v5Container = try ModelContainer(for: v5Schema, configurations: [v5Configuration])
            let context = ModelContext(v5Container)
            let imported = SchemaV5.SpendTransaction(
                amount: 42.00,
                date: .now,
                merchantName: "Coffee Shop",
                type: .variable,
                entryMethod: .imported,
                plaidTransactionID: "plaid-existing"
            )
            let manual = SchemaV5.SpendTransaction(
                amount: 10.00,
                date: .now,
                merchantName: "Cash Tip",
                type: .variable,
                entryMethod: .manual
            )
            let goal = SchemaV5.SavingsGoal(
                targetAmount: 500,
                targetDate: Calendar.current.date(byAdding: .day, value: 30, to: .now)!,
                startDate: .now,
                startingBalance: 0,
                dailyBase: 10
            )
            context.insert(imported)
            context.insert(manual)
            context.insert(goal)
            try context.save()
        }

        let v6Schema = Schema(versionedSchema: SchemaV6.self)
        let v6Configuration = ModelConfiguration(schema: v6Schema, url: storeURL)
        let v6Container = try ModelContainer(
            for: v6Schema,
            migrationPlan: ReservoirMigrationPlan.self,
            configurations: [v6Configuration]
        )
        let context = ModelContext(v6Container)
        let fetchedTransactions = try context.fetch(FetchDescriptor<SchemaV6.SpendTransaction>())
        XCTAssertEqual(fetchedTransactions.count, 2)

        let importedRow = try XCTUnwrap(fetchedTransactions.first { $0.plaidTransactionID == "plaid-existing" })
        XCTAssertEqual(
            importedRow.plaidItemID, "existing-item-1",
            "an existing imported row must be backfilled to the item ID that was linked pre-migration, not left nil."
        )

        let manualRow = try XCTUnwrap(fetchedTransactions.first { $0.merchantName == "Cash Tip" })
        XCTAssertNil(manualRow.plaidItemID, "a manual entry must stay nil, matching the plaidTransactionID nil-for-manual convention.")

        let fetchedGoals = try context.fetch(FetchDescriptor<SchemaV6.SavingsGoal>())
        XCTAssertEqual(fetchedGoals.count, 1)
        XCTAssertEqual(
            fetchedGoals.first?.associatedItemIDs, [],
            "an existing goal must default to zero associated accounts — no backfill needed, this feature didn't exist before."
        )
    }

    /// Companion to the backfill test above: when *no* item was linked pre-migration
    /// (a fresh install, or a user who unlinked before ever updating), the backfill must
    /// be a no-op rather than crash or fabricate an item ID — every imported row simply
    /// stays `nil`, same as it would have under a plain lightweight migration.
    func testV5StoreMigratesToV6_withNoLinkedItemPreMigration_leavesPlaidItemIDNil() throws {
        let linkedItemStore = LinkedItemStore()
        let preExistingItems = linkedItemStore.loadAll()
        for item in preExistingItems { linkedItemStore.remove(itemID: item.itemID) }
        addTeardownBlock {
            for item in preExistingItems { linkedItemStore.save(item) }
        }

        let v5Schema = Schema(versionedSchema: SchemaV5.self)
        let v5Configuration = ModelConfiguration(schema: v5Schema, url: storeURL)
        do {
            let v5Container = try ModelContainer(for: v5Schema, configurations: [v5Configuration])
            let context = ModelContext(v5Container)
            context.insert(SchemaV5.SpendTransaction(
                amount: 42.00,
                date: .now,
                merchantName: "Coffee Shop",
                type: .variable,
                entryMethod: .imported,
                plaidTransactionID: "plaid-existing"
            ))
            try context.save()
        }

        let v6Schema = Schema(versionedSchema: SchemaV6.self)
        let v6Configuration = ModelConfiguration(schema: v6Schema, url: storeURL)
        let v6Container = try ModelContainer(
            for: v6Schema,
            migrationPlan: ReservoirMigrationPlan.self,
            configurations: [v6Configuration]
        )
        let context = ModelContext(v6Container)
        let fetchedTransactions = try context.fetch(FetchDescriptor<SchemaV6.SpendTransaction>())

        XCTAssertEqual(fetchedTransactions.count, 1)
        XCTAssertNil(fetchedTransactions.first?.plaidItemID, "with no pre-migration linked item, there is nothing to backfill to.")
    }

    /// Regression coverage for reservoir-loc.2: a store created under `SchemaV6` (as any
    /// pre-loc.2 build would have on disk) must open cleanly under `SchemaV7` via
    /// `ReservoirMigrationPlan`, with existing data intact and the new
    /// `PendingTransactionMerge.plaidItemID` field present, defaulted to `nil` for a
    /// pending row that predates it — see `SchemaV7`'s doc comment for why (unlike
    /// `SchemaV6`'s `plaidItemID` backfill for `SpendTransaction`) no backfill is needed
    /// or attempted here: a plain lightweight/inferred migration is correct.
    func testV6StoreMigratesToV7WithDataIntactAndPendingTransactionMergePlaidItemIDDefaultedNil() throws {
        let v6Schema = Schema(versionedSchema: SchemaV6.self)
        let v6Configuration = ModelConfiguration(schema: v6Schema, url: storeURL)
        do {
            let v6Container = try ModelContainer(for: v6Schema, configurations: [v6Configuration])
            let context = ModelContext(v6Container)
            let manual = SchemaV6.SpendTransaction(
                amount: 12.50,
                date: .now,
                merchantName: "Coffee Shop",
                type: .variable,
                entryMethod: .manual
            )
            context.insert(manual)
            let pending = SchemaV6.PendingTransactionMerge(
                plaidTransactionID: "plaid-pending-existing",
                incomingAmount: 12.50,
                incomingDate: .now,
                incomingMerchantName: "Coffee Shop",
                manualTransaction: manual
            )
            context.insert(pending)
            try context.save()
        }

        let v7Schema = Schema(versionedSchema: SchemaV7.self)
        let v7Configuration = ModelConfiguration(schema: v7Schema, url: storeURL)
        let v7Container = try ModelContainer(
            for: v7Schema,
            migrationPlan: ReservoirMigrationPlan.self,
            configurations: [v7Configuration]
        )
        let context = ModelContext(v7Container)
        // Explicitly `SchemaV7.PendingTransactionMerge`, not the bare alias — that alias
        // now points at `SchemaV7` anyway (this is the current version, unlike every
        // prior test in this file), but named explicitly here for consistency with every
        // stage's test above.
        let fetchedPending = try context.fetch(FetchDescriptor<SchemaV7.PendingTransactionMerge>())
        XCTAssertEqual(fetchedPending.count, 1)
        XCTAssertEqual(fetchedPending.first?.plaidTransactionID, "plaid-pending-existing")
        XCTAssertNil(
            fetchedPending.first?.plaidItemID,
            "a pending merge decision that predates this field must default to nil, not crash or fabricate a value."
        )

        let fetchedTransactions = try context.fetch(FetchDescriptor<SchemaV7.SpendTransaction>())
        XCTAssertEqual(fetchedTransactions.count, 1)
        XCTAssertEqual(fetchedTransactions.first?.merchantName, "Coffee Shop", "existing data must survive the migration intact.")
    }
}
