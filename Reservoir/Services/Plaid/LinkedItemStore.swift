import Foundation

/// Persists the single linked Plaid item's non-secret metadata (institution name, item
/// ID, linked date, and the `needsAttention` flag reservoir-adq.6.5 adds) — the
/// `access_token` itself lives only in Keychain, never here. `UserDefaults`-backed under
/// the `plaid.linkedItem` key, matching the shape `PlaidServiceLive` originally read/wrote
/// as private static helpers before this story extracted them into their own store.
///
/// A protocol so `PlaidServiceLive` and `TransactionImportService` — and their tests —
/// don't depend on `UserDefaults` directly, same reasoning as `KeychainServicing`/
/// `PlaidSyncCursorStoring`/`PlaidEnvironmentStoring`. Both services depend on this one
/// store via constructor-parameter DI rather than each owning a parallel persistence
/// mechanism: `PlaidServiceLive` still owns *writing* the item on a successful Link/relink
/// and clearing it on an environment change, while `TransactionImportService` only ever
/// flips `needsAttention` (via `setNeedsAttention(_:)`) when it classifies an item-level
/// auth error — it never constructs/persists a whole `LinkedItem` itself.
protocol LinkedItemStoring: Sendable {
    /// The currently persisted linked item, or `nil` if none has been linked (or it was
    /// cleared by an environment switch — see `PlaidEnvironmentStore.onChange`).
    func load() -> LinkedItem?
    /// Persists `item` in full, overwriting whatever was previously stored. Used by
    /// `PlaidServiceLive` after a successful Link exchange (new item) and after a
    /// successful update-mode relink (same item, `needsAttention` reset to `false`).
    func save(_ item: LinkedItem)
    /// Clears the persisted item entirely — used when the Plaid environment changes
    /// (a linked item is only ever valid for the environment it was linked under).
    func clear()
    /// Flips just the `needsAttention` flag on whatever item is currently stored, leaving
    /// every other field untouched. A no-op if nothing is currently stored (can't flag a
    /// connection that was never linked in the first place). This is the one write
    /// `TransactionImportService` needs — it has no other reason to touch linked-item
    /// metadata, so it's given this narrow, purpose-built method rather than a general
    /// `save(_:)` it would have to read-modify-write through itself.
    func setNeedsAttention(_ needsAttention: Bool)
}

final class LinkedItemStore: LinkedItemStoring, @unchecked Sendable {
    private static let defaultsKey = "plaid.linkedItem"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> LinkedItem? {
        guard let dict = defaults.dictionary(forKey: Self.defaultsKey),
              let itemID = dict["itemID"] as? String,
              let institutionName = dict["institutionName"] as? String,
              let linkedAtInterval = dict["linkedAt"] as? TimeInterval
        else {
            return nil
        }
        // `needsAttention` defaults to `false` when reading a dict written before this
        // story (or by UITestSupport's seeding helper, which doesn't set it) — an item
        // linked/seeded before this field existed is assumed healthy, not flagged.
        let needsAttention = dict["needsAttention"] as? Bool ?? false
        return LinkedItem(
            itemID: itemID,
            institutionName: institutionName,
            linkedAt: Date(timeIntervalSince1970: linkedAtInterval),
            needsAttention: needsAttention
        )
    }

    func save(_ item: LinkedItem) {
        let dict: [String: Any] = [
            "itemID": item.itemID,
            "institutionName": item.institutionName,
            "linkedAt": item.linkedAt.timeIntervalSince1970,
            "needsAttention": item.needsAttention,
        ]
        defaults.set(dict, forKey: Self.defaultsKey)
    }

    func clear() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }

    func setNeedsAttention(_ needsAttention: Bool) {
        guard var item = load() else { return }
        item.needsAttention = needsAttention
        save(item)
    }
}
