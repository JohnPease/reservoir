import Foundation

/// Persists the `/transactions/sync` cursor `TransactionImportService` needs to fetch
/// only what's changed since the last successful import (adq.6.3). `UserDefaults`-backed,
/// scoped per-`PlaidEnvironment`-per-item (reservoir-loc.1 — originally environment-only,
/// see that story for why a second linked item needs its own cursor): Sandbox and
/// Production are different linked items with unrelated transaction histories, and two
/// distinct linked items within the same environment are equally unrelated — a cursor
/// from one (environment, item) pair must never be read/advanced against another.
///
/// A protocol so `TransactionImportService` and its tests don't depend on
/// `UserDefaults` directly, same reasoning as `PlaidEnvironmentStoring`/
/// `KeychainServicing`.
protocol PlaidSyncCursorStoring: Sendable {
    func cursor(for environment: PlaidEnvironment, itemID: String) -> String?
    func setCursor(_ cursor: String?, for environment: PlaidEnvironment, itemID: String)
    func clearCursor(for environment: PlaidEnvironment, itemID: String)
}

final class PlaidSyncCursorStore: PlaidSyncCursorStoring, @unchecked Sendable {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func cursor(for environment: PlaidEnvironment, itemID: String) -> String? {
        defaults.string(forKey: key(for: environment, itemID: itemID))
    }

    func setCursor(_ cursor: String?, for environment: PlaidEnvironment, itemID: String) {
        guard let cursor else {
            clearCursor(for: environment, itemID: itemID)
            return
        }
        defaults.set(cursor, forKey: key(for: environment, itemID: itemID))
    }

    func clearCursor(for environment: PlaidEnvironment, itemID: String) {
        defaults.removeObject(forKey: key(for: environment, itemID: itemID))
    }

    private func key(for environment: PlaidEnvironment, itemID: String) -> String {
        "plaid.syncCursor.\(environment.rawValue).\(itemID)"
    }
}
