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
