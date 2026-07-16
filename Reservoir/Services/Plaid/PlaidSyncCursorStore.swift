import Foundation

/// Persists the `/transactions/sync` cursor `TransactionImportService` needs to fetch
/// only what's changed since the last successful import (adq.6.3). `UserDefaults`-backed,
/// scoped per-`PlaidEnvironment` via a key suffix — mirrors `PlaidEnvironmentStore`'s
/// shape/reasoning exactly (see `PlaidEnvironment.swift`): Sandbox and Production are
/// different linked items with unrelated transaction histories, so a cursor from one
/// must never be read/advanced against the other.
///
/// A protocol so `TransactionImportService` and its tests don't depend on
/// `UserDefaults` directly, same reasoning as `PlaidEnvironmentStoring`/
/// `KeychainServicing`.
protocol PlaidSyncCursorStoring: Sendable {
    func cursor(for environment: PlaidEnvironment) -> String?
    func setCursor(_ cursor: String?, for environment: PlaidEnvironment)
    func clearCursor(for environment: PlaidEnvironment)
}

final class PlaidSyncCursorStore: PlaidSyncCursorStoring, @unchecked Sendable {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func cursor(for environment: PlaidEnvironment) -> String? {
        defaults.string(forKey: key(for: environment))
    }

    func setCursor(_ cursor: String?, for environment: PlaidEnvironment) {
        guard let cursor else {
            clearCursor(for: environment)
            return
        }
        defaults.set(cursor, forKey: key(for: environment))
    }

    func clearCursor(for environment: PlaidEnvironment) {
        defaults.removeObject(forKey: key(for: environment))
    }

    private func key(for environment: PlaidEnvironment) -> String {
        "plaid.syncCursor.\(environment.rawValue)"
    }
}
