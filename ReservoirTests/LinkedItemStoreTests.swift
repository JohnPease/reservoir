import XCTest
@testable import Reservoir

/// Covers `LinkedItemStore`'s real `UserDefaults`-backed persistence — `loadAll()`/
/// `save(_:)`/`remove(itemID:)` round-tripping as an unbounded, upsert-by-itemID
/// collection (reservoir-loc.1), and the `needsAttention` flag `setNeedsAttention(_:
/// itemID:)` flips narrowly. Same bar as `PlaidSyncCursorStoreTests`' coverage of the
/// sibling `PlaidSyncCursorStore`; every other test in this suite exercises the two
/// consumers (`PlaidServiceLive`, `TransactionImportService`) against a
/// `StubLinkedItemStore`, so this file is the only place the real `UserDefaults`
/// reading/writing logic itself gets exercised.
final class LinkedItemStoreTests: XCTestCase {
    private func makeStore() -> LinkedItemStore {
        let suiteName = "LinkedItemStoreTests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        return LinkedItemStore(defaults: UserDefaults(suiteName: suiteName)!)
    }

    func testLoadAll_returnsEmpty_whenNothingPersisted() {
        let store = makeStore()
        XCTAssertTrue(store.loadAll().isEmpty)
    }

    func testSave_thenLoadAll_roundTrips() {
        let store = makeStore()
        let linkedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let item = LinkedItem(itemID: "item-1", institutionName: "Test Bank", linkedAt: linkedAt, needsAttention: true)

        store.save(item)

        let loaded = store.loadAll()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.itemID, "item-1")
        XCTAssertEqual(loaded.first?.institutionName, "Test Bank")
        XCTAssertEqual(loaded.first?.linkedAt, linkedAt)
        XCTAssertEqual(loaded.first?.needsAttention, true)
    }

    func testSave_defaultNeedsAttention_persistsAsFalse() {
        let store = makeStore()
        store.save(LinkedItem(itemID: "item-1", institutionName: "Test Bank", linkedAt: .now))

        XCTAssertEqual(store.loadAll().first?.needsAttention, false)
    }

    /// Regression coverage for the original overwrite bug this story fixes (reservoir-
    /// loc.1): saving a second, distinct item must never discard the first — the original
    /// `LinkedItemStore.save(_:)` unconditionally overwrote the one persisted item, so
    /// linking a second account silently destroyed the first account's local metadata
    /// even though it still existed on Plaid's side.
    func testSave_ofSecondDistinctItem_keepsBothItemsPresent() {
        let store = makeStore()
        store.save(LinkedItem(itemID: "item-1", institutionName: "Bank One", linkedAt: .now))
        store.save(LinkedItem(itemID: "item-2", institutionName: "Bank Two", linkedAt: .now))

        let loaded = store.loadAll()
        XCTAssertEqual(loaded.count, 2, "saving a second item must not discard the first.")
        XCTAssertTrue(loaded.contains { $0.itemID == "item-1" && $0.institutionName == "Bank One" })
        XCTAssertTrue(loaded.contains { $0.itemID == "item-2" && $0.institutionName == "Bank Two" })
    }

    /// No fixed cap on the number of linked items this store can hold.
    func testSave_ofManyItems_allArePersisted() {
        let store = makeStore()
        for index in 0..<10 {
            store.save(LinkedItem(itemID: "item-\(index)", institutionName: "Bank \(index)", linkedAt: .now))
        }

        XCTAssertEqual(store.loadAll().count, 10)
    }

    func testSave_ofExistingItemID_upsertsInPlace_doesNotAppendDuplicate() {
        let store = makeStore()
        store.save(LinkedItem(itemID: "item-1", institutionName: "Bank One", linkedAt: .now, needsAttention: false))
        store.save(LinkedItem(itemID: "item-1", institutionName: "Bank One Renamed", linkedAt: .now, needsAttention: true))

        let loaded = store.loadAll()
        XCTAssertEqual(loaded.count, 1, "an upsert of a matching itemID must replace in place, not append a duplicate.")
        XCTAssertEqual(loaded.first?.institutionName, "Bank One Renamed")
        XCTAssertEqual(loaded.first?.needsAttention, true)
    }

    func testRemove_removesOnlyTheMatchingItem() {
        let store = makeStore()
        store.save(LinkedItem(itemID: "item-1", institutionName: "Bank One", linkedAt: .now))
        store.save(LinkedItem(itemID: "item-2", institutionName: "Bank Two", linkedAt: .now))

        store.remove(itemID: "item-1")

        let loaded = store.loadAll()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.itemID, "item-2", "removing one item must leave every other item untouched.")
    }

    func testRemove_whenNothingPersisted_isANoOp() {
        let store = makeStore()
        store.remove(itemID: "item-1")
        XCTAssertTrue(store.loadAll().isEmpty)
    }

    func testRemove_ofUnknownItemID_leavesExistingItemsUntouched() {
        let store = makeStore()
        store.save(LinkedItem(itemID: "item-1", institutionName: "Bank One", linkedAt: .now))

        store.remove(itemID: "item-does-not-exist")

        XCTAssertEqual(store.loadAll().count, 1)
    }

    func testSetNeedsAttention_flipsFlag_onlyForMatchingItemID_leavesOthersUntouched() {
        let store = makeStore()
        let linkedAt = Date(timeIntervalSince1970: 1_700_000_000)
        store.save(LinkedItem(itemID: "item-1", institutionName: "Bank One", linkedAt: linkedAt, needsAttention: false))
        store.save(LinkedItem(itemID: "item-2", institutionName: "Bank Two", linkedAt: linkedAt, needsAttention: false))

        store.setNeedsAttention(true, itemID: "item-1")

        let loaded = store.loadAll()
        XCTAssertEqual(loaded.first { $0.itemID == "item-1" }?.needsAttention, true)
        XCTAssertEqual(loaded.first { $0.itemID == "item-2" }?.needsAttention, false, "flipping one item's flag must not affect another item.")
        XCTAssertEqual(loaded.first { $0.itemID == "item-1" }?.institutionName, "Bank One")
    }

    func testSetNeedsAttention_backToFalse_clearsFlag() {
        let store = makeStore()
        store.save(LinkedItem(itemID: "item-1", institutionName: "Test Bank", linkedAt: .now, needsAttention: true))

        store.setNeedsAttention(false, itemID: "item-1")

        XCTAssertEqual(store.loadAll().first?.needsAttention, false)
    }

    /// The one write `TransactionImportService` ever performs — must be a safe no-op when
    /// nothing matching `itemID` is linked yet (e.g. a stale/racing import attempt after
    /// the user unlinked), not a crash or a spuriously-created partial item.
    func testSetNeedsAttention_whenNothingPersisted_isANoOp() {
        let store = makeStore()

        store.setNeedsAttention(true, itemID: "item-1")

        XCTAssertTrue(store.loadAll().isEmpty, "must not fabricate a LinkedItem out of nothing.")
    }

    func testSetNeedsAttention_ofUnknownItemID_leavesExistingItemUntouched() {
        let store = makeStore()
        store.save(LinkedItem(itemID: "item-1", institutionName: "Test Bank", linkedAt: .now, needsAttention: false))

        store.setNeedsAttention(true, itemID: "item-does-not-exist")

        XCTAssertEqual(store.loadAll().first?.needsAttention, false)
    }
}
