import Foundation

/// Per-environment, per-item "account backfill done" flag (reservoir-j8t PR1), stored
/// next to `PlaidSyncCursorStore`'s cursors with the same keying. Rows imported before
/// `SpendTransaction.plaidAccountID` existed have no account; the one-time backfill
/// replays `/transactions/sync` from a nil cursor so each existing row can be stamped.
/// While this flag is unset for an item that already has a stored cursor,
/// `TransactionImportService` starts that item from a nil cursor; the flag is set only
/// after the whole replay finishes (`has_more == false`, every page handled). Fresh links
/// start with a nil cursor anyway, so they set it on their first complete pass.
protocol PlaidAccountBackfillStoring: Sendable {
    func isComplete(for environment: PlaidEnvironment, itemID: String) -> Bool
    func setComplete(for environment: PlaidEnvironment, itemID: String)
    func clear(for environment: PlaidEnvironment, itemID: String)
}

final class PlaidAccountBackfillStore: PlaidAccountBackfillStoring, @unchecked Sendable {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func isComplete(for environment: PlaidEnvironment, itemID: String) -> Bool {
        defaults.bool(forKey: key(for: environment, itemID: itemID))
    }

    func setComplete(for environment: PlaidEnvironment, itemID: String) {
        defaults.set(true, forKey: key(for: environment, itemID: itemID))
    }

    func clear(for environment: PlaidEnvironment, itemID: String) {
        defaults.removeObject(forKey: key(for: environment, itemID: itemID))
    }

    private func key(for environment: PlaidEnvironment, itemID: String) -> String {
        "plaid.accountBackfill.\(environment.rawValue).\(itemID)"
    }
}
