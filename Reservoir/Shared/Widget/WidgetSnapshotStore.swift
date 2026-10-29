import Foundation

/// Where the app and the widget extension meet. The App Group container holds one small
/// JSON file; SwiftData's store is deliberately not shared.
enum WidgetAppGroup {
    static let identifier = "group.com.johnpease.Reservoir"
    static let snapshotFileName = "widget-snapshot.json"
}

protocol WidgetSnapshotStoring: Sendable {
    /// `nil` when nothing was written yet, the file is unreadable, or it was written by a
    /// different snapshot version.
    func load() -> WidgetSnapshot?
    func save(_ snapshot: WidgetSnapshot) throws
}

/// File-backed store. `fileURL == nil` (App Group container unavailable, e.g. an
/// unsigned build) makes `load()` return `nil` and `save` a no-op rather than crash.
struct FileWidgetSnapshotStore: WidgetSnapshotStoring {
    let fileURL: URL?

    init(fileURL: URL?) {
        self.fileURL = fileURL
    }

    /// The App Group-backed store both targets use.
    static func appGroup(fileManager: FileManager = .default) -> FileWidgetSnapshotStore {
        let url = fileManager
            .containerURL(forSecurityApplicationGroupIdentifier: WidgetAppGroup.identifier)?
            .appendingPathComponent(WidgetAppGroup.snapshotFileName)
        return FileWidgetSnapshotStore(fileURL: url)
    }

    func load() -> WidgetSnapshot? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data),
              snapshot.version == WidgetSnapshot.currentVersion
        else { return nil }
        return snapshot
    }

    func save(_ snapshot: WidgetSnapshot) throws {
        guard let fileURL else { return }
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: fileURL, options: [.atomic])
    }
}
