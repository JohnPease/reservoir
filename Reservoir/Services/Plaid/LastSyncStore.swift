import Foundation

/// When the last `/transactions/sync` run finished a clean pass for every item it covered (reservoir-3oe), so the app can
/// say how fresh its imported data is. Stored in `UserDefaults` like the cursor store.
protocol LastSyncStoring: Sendable {
    var lastSuccessfulSync: Date? { get }
    func setLastSuccessfulSync(_ date: Date)
}

final class LastSyncStore: LastSyncStoring, @unchecked Sendable {
    private static let key = "plaid.lastSuccessfulSync"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var lastSuccessfulSync: Date? {
        defaults.object(forKey: Self.key) as? Date
    }

    func setLastSuccessfulSync(_ date: Date) {
        defaults.set(date, forKey: Self.key)
    }
}
