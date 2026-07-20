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
/// without touching real `UserDefaults`.
final class StubCursorStore: PlaidSyncCursorStoring, @unchecked Sendable {
    private var cursors: [PlaidEnvironment: String] = [:]
    func cursor(for environment: PlaidEnvironment) -> String? { cursors[environment] }
    func setCursor(_ cursor: String?, for environment: PlaidEnvironment) { cursors[environment] = cursor }
    func clearCursor(for environment: PlaidEnvironment) { cursors[environment] = nil }
}

/// A simple in-memory `LinkedItemStoring` stub (reservoir-adq.6.5) — backs
/// `TransactionImportServiceTests` and `PlaidServiceLiveTests` without touching real
/// `UserDefaults`. Records every `setNeedsAttention(_:)` call (not just the final state)
/// so a test can assert *that* the flag was set, distinct from asserting its final value —
/// useful for proving a transient/network error path never calls it at all.
final class StubLinkedItemStore: LinkedItemStoring, @unchecked Sendable {
    private var current: LinkedItem?
    private(set) var setNeedsAttentionCalls: [Bool] = []

    init(initial: LinkedItem? = nil) {
        self.current = initial
    }

    func load() -> LinkedItem? { current }
    func save(_ item: LinkedItem) { current = item }
    func clear() { current = nil }
    func setNeedsAttention(_ needsAttention: Bool) {
        setNeedsAttentionCalls.append(needsAttention)
        current?.needsAttention = needsAttention
    }
}
