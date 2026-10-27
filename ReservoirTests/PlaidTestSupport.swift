import Foundation
@testable import Reservoir

/// A no-op `KeychainServicing` stub shared by Plaid unit tests that only
/// care about `PlaidServiceLive`'s non-Keychain behavior (Link session
/// lifecycle, environment resolution) — kept in one place per STANDARDS'
/// no-duplicated-logic rule rather than redefined per test file.
final class StubKeychain: KeychainServicing, @unchecked Sendable {
    func save(_ value: String, for key: String) async throws {}
    func read(for key: String) async throws -> String? { nil }
    func delete(for key: String) async throws {}
}

/// A `KeychainServicing` stub that reports a fixed access token as already stored —
/// backs `TransactionImportServiceTests`, which needs `runImport()` to get past its
/// "no linked item, no-op" guard.
final class StubKeychainWithToken: KeychainServicing, @unchecked Sendable {
    private let token: String
    init(token: String = "access-sandbox-test") { self.token = token }
    func save(_ value: String, for key: String) async throws {}
    func read(for key: String) async throws -> String? { token }
    func delete(for key: String) async throws {}
}

/// A simple in-memory `PlaidEnvironmentStoring` stub — moved here (originally private to
/// `PlaidEnvironmentTests`) so `TransactionImportServiceTests` can reuse it too, per
/// STANDARDS' no-duplicated-logic rule.
final class StubEnvironmentStore: PlaidEnvironmentStoring, @unchecked Sendable {
    var current: PlaidEnvironment
    init(_ initial: PlaidEnvironment = .sandbox) { self.current = initial }
    func set(_ environment: PlaidEnvironment) { current = environment }
}

/// A simple in-memory `PlaidSyncCursorStoring` stub — backs `TransactionImportServiceTests`
/// without touching real `UserDefaults`. Keyed by `(environment, itemID)` (reservoir-loc.1).
final class StubCursorStore: PlaidSyncCursorStoring, @unchecked Sendable {
    private struct Key: Hashable { let environment: PlaidEnvironment; let itemID: String }
    private var cursors: [Key: String] = [:]
    func cursor(for environment: PlaidEnvironment, itemID: String) -> String? {
        cursors[Key(environment: environment, itemID: itemID)]
    }
    func setCursor(_ cursor: String?, for environment: PlaidEnvironment, itemID: String) {
        cursors[Key(environment: environment, itemID: itemID)] = cursor
    }
    func clearCursor(for environment: PlaidEnvironment, itemID: String) {
        cursors[Key(environment: environment, itemID: itemID)] = nil
    }
    func storedEntries() -> [(environment: PlaidEnvironment, itemID: String)] {
        cursors.keys.map { ($0.environment, $0.itemID) }
    }
}

/// A simple in-memory `LinkedItemStoring` stub (reservoir-adq.6.5, rebuilt as a
/// multi-item collection for reservoir-loc.1) — backs `TransactionImportServiceTests` and
/// `PlaidServiceLiveTests` without touching real `UserDefaults`. Records every
/// `setNeedsAttention(_:itemID:)` call (not just the final state) so a test can assert
/// *that* the flag was set, distinct from asserting its final value — useful for proving
/// a transient/network error path never calls it at all.
final class StubLinkedItemStore: LinkedItemStoring, @unchecked Sendable {
    private var items: [LinkedItem]
    private(set) var setNeedsAttentionCalls: [Bool] = []

    init(initial: LinkedItem? = nil) {
        self.items = initial.map { [$0] } ?? []
    }

    func loadAll() -> [LinkedItem] { items }

    func save(_ item: LinkedItem) {
        if let index = items.firstIndex(where: { $0.itemID == item.itemID }) {
            items[index] = item
        } else {
            items.append(item)
        }
    }

    func remove(itemID: String) {
        items.removeAll { $0.itemID == itemID }
    }

    func setNeedsAttention(_ needsAttention: Bool, itemID: String) {
        setNeedsAttentionCalls.append(needsAttention)
        guard let index = items.firstIndex(where: { $0.itemID == itemID }) else { return }
        items[index].needsAttention = needsAttention
    }
}

/// In-memory `LinkedAccountStoring` stub (reservoir-j8t) — shares `LinkedAccount.upserting`
/// with the real store so merge semantics are exercised, not re-implemented.
final class StubLinkedAccountStore: LinkedAccountStoring, @unchecked Sendable {
    private(set) var accounts: [LinkedAccount] = []
    private(set) var removedItemIDs: [String] = []
    func loadAll() -> [LinkedAccount] { accounts }
    func upsert(_ incoming: [LinkedAccount]) {
        accounts = LinkedAccount.upserting(incoming, into: accounts)
    }
    func removeAll(itemID: String) {
        removedItemIDs.append(itemID)
        accounts.removeAll { $0.itemID == itemID }
    }
}

/// In-memory `PlaidAccountBackfillStoring` stub (reservoir-j8t).
final class StubAccountBackfillStore: PlaidAccountBackfillStoring, @unchecked Sendable {
    private struct Key: Hashable { let environment: PlaidEnvironment; let itemID: String }
    private var done: Set<Key> = []
    /// When true, every (environment, item) reports complete unless explicitly `clear`ed
    /// — lets pre-backfill tests keep using their seeded cursors as-is.
    private let defaultComplete: Bool
    private var cleared: Set<Key> = []
    init(defaultComplete: Bool = false) { self.defaultComplete = defaultComplete }
    func isComplete(for environment: PlaidEnvironment, itemID: String) -> Bool {
        let key = Key(environment: environment, itemID: itemID)
        return done.contains(key) || (defaultComplete && !cleared.contains(key))
    }
    func setComplete(for environment: PlaidEnvironment, itemID: String) {
        done.insert(Key(environment: environment, itemID: itemID))
        cleared.remove(Key(environment: environment, itemID: itemID))
    }
    func clear(for environment: PlaidEnvironment, itemID: String) {
        done.remove(Key(environment: environment, itemID: itemID))
        cleared.insert(Key(environment: environment, itemID: itemID))
    }
}
