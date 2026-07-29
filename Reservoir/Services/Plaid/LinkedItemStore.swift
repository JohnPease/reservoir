import Foundation

/// Persists the linked Plaid items' non-secret metadata (institution name, item ID,
/// linked date, and the `needsAttention` flag reservoir-adq.6.5 adds) — the
/// `access_token` itself lives only in Keychain, never here. `UserDefaults`-backed under
/// the `plaid.linkedItems` key as one JSON-encoded array (reservoir-loc.1), replacing the
/// original single-`LinkedItem`-under-`plaid.linkedItem` shape.
///
/// **Unbounded, keyed by item ID, upsert-on-save** (reservoir-loc.1): the original
/// `save(_:)` unconditionally overwrote the one persisted item, so linking a second
/// account silently destroyed the first account's local metadata even though the item
/// still existed on Plaid's side — a live data-loss bug, not just a missing feature. This
/// store now holds a collection; `save(_:)` upserts by `itemID` (replacing a matching
/// existing entry in place, appending otherwise) and never touches any other item's
/// entry. No fixed cap on how many items can be stored.
///
/// A protocol so `PlaidServiceLive` and `TransactionImportService` — and their tests —
/// don't depend on `UserDefaults` directly, same reasoning as `KeychainServicing`/
/// `PlaidSyncCursorStoring`/`PlaidEnvironmentStoring`. Both services depend on this one
/// store via constructor-parameter DI rather than each owning a parallel persistence
/// mechanism: `PlaidServiceLive` still owns *writing* an item on a successful Link/relink
/// and removing items on an environment change, while `TransactionImportService` only
/// ever flips `needsAttention` (via `setNeedsAttention(_:itemID:)`) when it classifies an
/// item-level auth error — it never constructs/persists a whole `LinkedItem` itself.
protocol LinkedItemStoring: Sendable {
    /// Every currently persisted linked item, in no particular order. Empty if none has
    /// ever been linked (or all were removed — see `remove(itemID:)` and
    /// `PlaidEnvironmentStore.onChange`).
    func loadAll() -> [LinkedItem]
    /// Upserts `item` by `itemID`: replaces the existing entry with that ID if one
    /// exists, otherwise appends `item` as a new entry. Never overwrites or discards any
    /// other item's stored metadata — this is the fix for the original overwrite-on-save
    /// bug. Used by `PlaidServiceLive` after a successful Link exchange (new item) and
    /// after a successful update-mode relink (same item, `needsAttention` reset to
    /// `false`).
    func save(_ item: LinkedItem)
    /// Removes just the item matching `itemID`, leaving every other persisted item
    /// untouched. A no-op if no item with that ID is currently stored. Used when the
    /// Plaid environment changes (an item is only ever valid for the environment it was
    /// linked under) and when a single item is unlinked.
    func remove(itemID: String)
    /// Flips just the `needsAttention` flag on the item matching `itemID`, leaving every
    /// other field — and every other item — untouched. A no-op if no item with that ID
    /// is currently stored (can't flag a connection that was never linked in the first
    /// place). This is the one write `TransactionImportService` needs — it has no other
    /// reason to touch linked-item metadata, so it's given this narrow, purpose-built
    /// method rather than a general `save(_:)` it would have to read-modify-write through
    /// itself.
    func setNeedsAttention(_ needsAttention: Bool, itemID: String)
}

final class LinkedItemStore: LinkedItemStoring, @unchecked Sendable {
    private static let defaultsKey = "plaid.linkedItems"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadAll() -> [LinkedItem] {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([LinkedItem].self, from: data)) ?? []
    }

    func save(_ item: LinkedItem) {
        var items = loadAll()
        if let index = items.firstIndex(where: { $0.itemID == item.itemID }) {
            items[index] = item
        } else {
            items.append(item)
        }
        persist(items)
    }

    func remove(itemID: String) {
        var items = loadAll()
        items.removeAll { $0.itemID == itemID }
        persist(items)
    }

    func setNeedsAttention(_ needsAttention: Bool, itemID: String) {
        var items = loadAll()
        guard let index = items.firstIndex(where: { $0.itemID == itemID }) else { return }
        items[index].needsAttention = needsAttention
        persist(items)
    }

    private func persist(_ items: [LinkedItem]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
