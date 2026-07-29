import XCTest
@testable import Reservoir

/// Covers `PlaidSyncCursorStore`: persistence, per-`(environment, itemID)` scoping
/// (reservoir-loc.1 — originally environment-only), and clearing — same bar as
/// `PlaidEnvironmentTests`' coverage of `PlaidEnvironmentStore`. The `PlaidServiceLive
/// .onChange`-hook clear-on-environment-change wiring itself is covered separately, in
/// `test_realEnvironmentChange_alsoClearsSyncCursorsForEveryLinkedItem` below, which needs
/// a `LinkedItemStore` in the mix now that the hook iterates every linked item rather than
/// clearing one fixed set of keys.
final class PlaidSyncCursorStoreTests: XCTestCase {
    private func makeStore() -> PlaidSyncCursorStore {
        let suiteName = "PlaidSyncCursorStoreTests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        return PlaidSyncCursorStore(defaults: UserDefaults(suiteName: suiteName)!)
    }

    func testCursor_defaultsToNil_whenNothingPersisted() {
        let store = makeStore()
        XCTAssertNil(store.cursor(for: .sandbox, itemID: "item-1"))
    }

    func testSetCursor_persistsForThatEnvironmentAndItem() {
        let store = makeStore()
        store.setCursor("cursor-abc", for: .sandbox, itemID: "item-1")
        XCTAssertEqual(store.cursor(for: .sandbox, itemID: "item-1"), "cursor-abc")
    }

    func testSetCursor_isScopedPerEnvironment() {
        let store = makeStore()
        store.setCursor("cursor-sandbox", for: .sandbox, itemID: "item-1")
        store.setCursor("cursor-production", for: .production, itemID: "item-1")

        XCTAssertEqual(store.cursor(for: .sandbox, itemID: "item-1"), "cursor-sandbox")
        XCTAssertEqual(store.cursor(for: .production, itemID: "item-1"), "cursor-production")
    }

    /// The actual reservoir-loc.1 addition: two distinct linked items within the *same*
    /// environment must not share a cursor — Plaid's `/transactions/sync` cursors are
    /// item-scoped on Plaid's side too, so reusing one item's cursor for another's sync
    /// call would desync the pagination entirely.
    func testSetCursor_isScopedPerItemID_withinTheSameEnvironment() {
        let store = makeStore()
        store.setCursor("cursor-item-1", for: .sandbox, itemID: "item-1")
        store.setCursor("cursor-item-2", for: .sandbox, itemID: "item-2")

        XCTAssertEqual(store.cursor(for: .sandbox, itemID: "item-1"), "cursor-item-1")
        XCTAssertEqual(store.cursor(for: .sandbox, itemID: "item-2"), "cursor-item-2")
    }

    func testSetCursor_withNil_clearsIt() {
        let store = makeStore()
        store.setCursor("cursor-abc", for: .sandbox, itemID: "item-1")
        store.setCursor(nil, for: .sandbox, itemID: "item-1")
        XCTAssertNil(store.cursor(for: .sandbox, itemID: "item-1"))
    }

    func testClearCursor_removesOnlyThatEnvironmentAndItem() {
        let store = makeStore()
        store.setCursor("cursor-sandbox-item-1", for: .sandbox, itemID: "item-1")
        store.setCursor("cursor-production-item-1", for: .production, itemID: "item-1")
        store.setCursor("cursor-sandbox-item-2", for: .sandbox, itemID: "item-2")

        store.clearCursor(for: .sandbox, itemID: "item-1")

        XCTAssertNil(store.cursor(for: .sandbox, itemID: "item-1"))
        XCTAssertEqual(store.cursor(for: .production, itemID: "item-1"), "cursor-production-item-1")
        XCTAssertEqual(store.cursor(for: .sandbox, itemID: "item-2"), "cursor-sandbox-item-2", "clearing item-1's sandbox cursor must not touch item-2's.")
    }

    func testSetCursor_overwritesPreviousValue() {
        let store = makeStore()
        store.setCursor("cursor-1", for: .sandbox, itemID: "item-1")
        store.setCursor("cursor-2", for: .sandbox, itemID: "item-1")
        XCTAssertEqual(store.cursor(for: .sandbox, itemID: "item-1"), "cursor-2")
    }

    // MARK: - PlaidServiceLive's onChange hook also clears sync cursors, for every item

    @MainActor
    func test_realEnvironmentChange_alsoClearsSyncCursorsForEveryLinkedItem() async {
        let environmentSuiteName = "PlaidSyncCursorStoreTests.onChange.env.\(UUID().uuidString)"
        let linkedItemSuiteName = "PlaidSyncCursorStoreTests.onChange.linkedItem.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: environmentSuiteName) }
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: linkedItemSuiteName) }

        let environmentStore = PlaidEnvironmentStore(defaults: UserDefaults(suiteName: environmentSuiteName)!)
        let cursorStore = makeStore()
        let linkedItemStore = LinkedItemStore(defaults: UserDefaults(suiteName: linkedItemSuiteName)!)
        linkedItemStore.save(LinkedItem(itemID: "item-1", institutionName: "Bank One", linkedAt: .now))
        linkedItemStore.save(LinkedItem(itemID: "item-2", institutionName: "Bank Two", linkedAt: .now))
        cursorStore.setCursor("cursor-sandbox-item-1", for: .sandbox, itemID: "item-1")
        cursorStore.setCursor("cursor-production-item-1", for: .production, itemID: "item-1")
        cursorStore.setCursor("cursor-sandbox-item-2", for: .sandbox, itemID: "item-2")

        let sut = PlaidServiceLive(
            keychain: StubKeychain(),
            urlSession: .shared,
            environmentStore: environmentStore,
            cursorStore: cursorStore,
            linkedItemStore: linkedItemStore
        )
        _ = sut // keep alive for the duration of this test

        environmentStore.set(.production)

        // The clear happens synchronously inside onChange (unlike the Keychain
        // delete/linkedItem removal, which hops onto a Task) — no yield needed.
        XCTAssertNil(cursorStore.cursor(for: .sandbox, itemID: "item-1"))
        XCTAssertNil(cursorStore.cursor(for: .production, itemID: "item-1"))
        XCTAssertNil(cursorStore.cursor(for: .sandbox, itemID: "item-2"), "every linked item's cursors must be invalidated, not just the first.")
    }
}
