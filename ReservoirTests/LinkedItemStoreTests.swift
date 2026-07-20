import XCTest
@testable import Reservoir

/// Covers `LinkedItemStore`'s real `UserDefaults`-backed persistence — save/load/clear
/// round-tripping, the `needsAttention` flag `setNeedsAttention(_:)` flips narrowly, and
/// the pre-adq.6.5-dict backward-compatibility fallback. Same bar as
/// `PlaidSyncCursorStoreTests`' coverage of the sibling `PlaidSyncCursorStore`; every other
/// test in this suite exercises the two consumers (`PlaidServiceLive`,
/// `TransactionImportService`) against a `StubLinkedItemStore`, so this file is the only
/// place the real `UserDefaults` reading/writing logic itself gets exercised.
final class LinkedItemStoreTests: XCTestCase {
    private func makeStore() -> LinkedItemStore {
        let suiteName = "LinkedItemStoreTests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        return LinkedItemStore(defaults: UserDefaults(suiteName: suiteName)!)
    }

    func testLoad_returnsNil_whenNothingPersisted() {
        let store = makeStore()
        XCTAssertNil(store.load())
    }

    func testSave_thenLoad_roundTrips() {
        let store = makeStore()
        let linkedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let item = LinkedItem(itemID: "item-1", institutionName: "Test Bank", linkedAt: linkedAt, needsAttention: true)

        store.save(item)

        let loaded = store.load()
        XCTAssertEqual(loaded?.itemID, "item-1")
        XCTAssertEqual(loaded?.institutionName, "Test Bank")
        XCTAssertEqual(loaded?.linkedAt, linkedAt)
        XCTAssertEqual(loaded?.needsAttention, true)
    }

    func testSave_defaultNeedsAttention_persistsAsFalse() {
        let store = makeStore()
        store.save(LinkedItem(itemID: "item-1", institutionName: "Test Bank", linkedAt: .now))

        XCTAssertEqual(store.load()?.needsAttention, false)
    }

    func testSave_overwritesPreviousItem() {
        let store = makeStore()
        store.save(LinkedItem(itemID: "item-1", institutionName: "Bank One", linkedAt: .now))
        store.save(LinkedItem(itemID: "item-2", institutionName: "Bank Two", linkedAt: .now))

        XCTAssertEqual(store.load()?.itemID, "item-2")
        XCTAssertEqual(store.load()?.institutionName, "Bank Two")
    }

    func testClear_removesPersistedItem() {
        let store = makeStore()
        store.save(LinkedItem(itemID: "item-1", institutionName: "Test Bank", linkedAt: .now))

        store.clear()

        XCTAssertNil(store.load())
    }

    func testClear_whenNothingPersisted_isANoOp() {
        let store = makeStore()
        store.clear()
        XCTAssertNil(store.load())
    }

    func testSetNeedsAttention_flipsFlag_leavesOtherFieldsUntouched() {
        let store = makeStore()
        let linkedAt = Date(timeIntervalSince1970: 1_700_000_000)
        store.save(LinkedItem(itemID: "item-1", institutionName: "Test Bank", linkedAt: linkedAt, needsAttention: false))

        store.setNeedsAttention(true)

        let loaded = store.load()
        XCTAssertEqual(loaded?.needsAttention, true)
        XCTAssertEqual(loaded?.itemID, "item-1")
        XCTAssertEqual(loaded?.institutionName, "Test Bank")
        XCTAssertEqual(loaded?.linkedAt, linkedAt)
    }

    func testSetNeedsAttention_backToFalse_clearsFlag() {
        let store = makeStore()
        store.save(LinkedItem(itemID: "item-1", institutionName: "Test Bank", linkedAt: .now, needsAttention: true))

        store.setNeedsAttention(false)

        XCTAssertEqual(store.load()?.needsAttention, false)
    }

    /// The one write `TransactionImportService` ever performs — must be a safe no-op when
    /// nothing is linked yet (e.g. a stale/racing import attempt after the user unlinked),
    /// not a crash or a spuriously-created partial item.
    func testSetNeedsAttention_whenNothingPersisted_isANoOp() {
        let store = makeStore()

        store.setNeedsAttention(true)

        XCTAssertNil(store.load(), "must not fabricate a LinkedItem out of nothing.")
    }

    /// A dict written before this story added `needsAttention` (or by
    /// `UITestSupport.seedPlaidLinkedItemIfRequested()`'s older seeding shape) has no
    /// `needsAttention` key at all — `load()` must default that to `false` (an item
    /// linked/seeded before the flag existed is assumed healthy) rather than crashing or
    /// returning `nil` outright, per `load()`'s doc comment.
    func testLoad_dictMissingNeedsAttentionKey_defaultsToFalse() {
        let suiteName = "LinkedItemStoreTests.legacyDict.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(
            [
                "itemID": "legacy-item",
                "institutionName": "Legacy Bank",
                "linkedAt": Date().timeIntervalSince1970,
            ],
            forKey: "plaid.linkedItem"
        )
        let store = LinkedItemStore(defaults: defaults)

        let loaded = store.load()

        XCTAssertEqual(loaded?.itemID, "legacy-item")
        XCTAssertEqual(loaded?.needsAttention, false)
    }

    func testLoad_missingRequiredKeys_returnsNil() {
        let suiteName = "LinkedItemStoreTests.malformed.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(["itemID": "item-1"], forKey: "plaid.linkedItem") // missing institutionName/linkedAt
        let store = LinkedItemStore(defaults: defaults)

        XCTAssertNil(store.load())
    }
}
