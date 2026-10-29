import Foundation

/// A capped, on-device record of every `/transactions/sync` run (reservoir-bz5), so a
/// charge that never shows up can be traced to "the sync never ran", "Plaid returned
/// nothing", or "the app dropped it". Lines carry counts, dates and Plaid-side status
/// only: never a merchant name, an amount or an access token.
protocol SyncLogStoring: Sendable {
    func append(_ message: String)
    func entries() -> [SyncLogEntry]
    func clear()
}

struct SyncLogEntry: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var date: Date
    var message: String
}

/// JSON file in Application Support, rewritten on each append (a few hundred short
/// lines at most). Guarded by a lock because syncs run on the main actor while the
/// viewer may read from anywhere.
final class SyncLogStore: SyncLogStoring, @unchecked Sendable {
    static let maxEntries = 500

    private let url: URL
    private let now: @Sendable () -> Date
    private let lock = NSLock()

    init(url: URL = SyncLogStore.defaultURL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.url = url
        self.now = now
    }

    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("sync-log.json")
    }

    func append(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        var all = load()
        all.append(SyncLogEntry(date: now(), message: message))
        if all.count > Self.maxEntries { all.removeFirst(all.count - Self.maxEntries) }
        save(all)
    }

    func entries() -> [SyncLogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return load()
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
    }

    private func load() -> [SyncLogEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([SyncLogEntry].self, from: data)) ?? []
    }

    private func save(_ entries: [SyncLogEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// Plain-text rendering for the viewer's copy/share button.
enum SyncLogFormatter {
    static func text(_ entries: [SyncLogEntry]) -> String {
        let style = Date.ISO8601FormatStyle(includingFractionalSeconds: false, timeZone: .current)
        return entries.map { "\($0.date.formatted(style)) \($0.message)" }.joined(separator: "\n")
    }
}
