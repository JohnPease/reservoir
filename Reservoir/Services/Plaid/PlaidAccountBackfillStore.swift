import Foundation

/// Per-environment, per-item "account backfill done" flag (reservoir-j8t PR1), stored
/// next to `PlaidSyncCursorStore`'s cursors with the same keying. Rows imported before
/// `SpendTransaction.plaidAccountID` existed have no account; the one-time backfill
/// replays `/transactions/sync` from a nil cursor, in a stamp-only pass, so each existing
/// row can be stamped. While this flag is unset for an item that already has a stored
/// cursor, `TransactionImportService` first runs the ordinary incremental sync from that
/// cursor and then the stamp-only replay (which writes nothing but a nil `plaidAccountID`
/// and persists no cursor); the flag is set only after the replay finishes
/// (`has_more == false`, every page handled, item still linked). Fresh links have no stored
/// cursor, so they need no replay and set it on their first complete pass.
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
        // "v2" (reservoir-z4p): bumped so every item replays once more and refreshes
        // `isPending` on rows imported before that flag existed.
        "plaid.accountBackfill.v2.\(environment.rawValue).\(itemID)"
    }
}
