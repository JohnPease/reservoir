import XCTest
@testable import Reservoir

/// Covers `PlaidSyncCursorStore`: persistence, per-`PlaidEnvironment` scoping, and
/// clearing — same bar as `PlaidEnvironmentTests`' coverage of `PlaidEnvironmentStore`.
/// The `PlaidServiceLive.onChange`-hook clear-on-environment-change wiring itself is
/// covered separately, in `PlaidEnvironmentTests` (it already owns the
/// `onChange`-invalidation test fixture) — see
/// `test_realEnvironmentChange_alsoClearsSyncCursors`.
final class PlaidSyncCursorStoreTests: XCTestCase {
    private func makeStore() -> PlaidSyncCursorStore {
        let suiteName = "PlaidSyncCursorStoreTests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        return PlaidSyncCursorStore(defaults: UserDefaults(suiteName: suiteName)!)
    }

    func testCursor_defaultsToNil_whenNothingPersisted() {
        let store = makeStore()
        XCTAssertNil(store.cursor(for: .sandbox))
    }

    func testSetCursor_persistsForThatEnvironment() {
        let store = makeStore()
        store.setCursor("cursor-abc", for: .sandbox)
        XCTAssertEqual(store.cursor(for: .sandbox), "cursor-abc")
    }

    func testSetCursor_isScopedPerEnvironment() {
        let store = makeStore()
        store.setCursor("cursor-sandbox", for: .sandbox)
        store.setCursor("cursor-production", for: .production)

        XCTAssertEqual(store.cursor(for: .sandbox), "cursor-sandbox")
        XCTAssertEqual(store.cursor(for: .production), "cursor-production")
    }

    func testSetCursor_withNil_clearsIt() {
        let store = makeStore()
        store.setCursor("cursor-abc", for: .sandbox)
        store.setCursor(nil, for: .sandbox)
        XCTAssertNil(store.cursor(for: .sandbox))
    }

    func testClearCursor_removesOnlyThatEnvironment() {
        let store = makeStore()
        store.setCursor("cursor-sandbox", for: .sandbox)
        store.setCursor("cursor-production", for: .production)

        store.clearCursor(for: .sandbox)

        XCTAssertNil(store.cursor(for: .sandbox))
        XCTAssertEqual(store.cursor(for: .production), "cursor-production")
    }

    func testSetCursor_overwritesPreviousValue() {
        let store = makeStore()
        store.setCursor("cursor-1", for: .sandbox)
        store.setCursor("cursor-2", for: .sandbox)
        XCTAssertEqual(store.cursor(for: .sandbox), "cursor-2")
    }

    // MARK: - PlaidServiceLive's onChange hook also clears sync cursors

    @MainActor
    func test_realEnvironmentChange_alsoClearsSyncCursors() async {
        let suiteName = "PlaidSyncCursorStoreTests.onChange.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let environmentStore = PlaidEnvironmentStore(defaults: UserDefaults(suiteName: suiteName)!)
        let cursorStore = makeStore()
        cursorStore.setCursor("cursor-sandbox", for: .sandbox)
        cursorStore.setCursor("cursor-production", for: .production)

        let sut = PlaidServiceLive(
            keychain: StubKeychain(),
            urlSession: .shared,
            environmentStore: environmentStore,
            cursorStore: cursorStore
        )
        _ = sut // keep alive for the duration of this test

        environmentStore.set(.production)

        // The clear happens synchronously inside onChange (unlike the Keychain
        // delete/linkedItem clear, which hops onto a Task) — no yield needed.
        XCTAssertNil(cursorStore.cursor(for: .sandbox))
        XCTAssertNil(cursorStore.cursor(for: .production))
    }
}
