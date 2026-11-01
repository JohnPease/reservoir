import XCTest
@testable import Reservoir

/// Test double shared by the import-service tests.
final class InMemorySyncLog: SyncLogStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [SyncLogEntry] = []
    var messages: [String] { entries().map(\.message) }
    func append(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        stored.append(SyncLogEntry(date: Date(), message: message))
    }
    func entries() -> [SyncLogEntry] { lock.lock(); defer { lock.unlock() }; return stored }
    func clear() { lock.lock(); defer { lock.unlock() }; stored = [] }
}

final class SyncLogStoreTests: XCTestCase {
    private var url: URL!

    override func setUp() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("sync-log-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
    }

    func test_append_persistsAcrossInstances() {
        SyncLogStore(url: url).append("one")
        SyncLogStore(url: url).append("two")
        XCTAssertEqual(SyncLogStore(url: url).entries().map(\.message), ["one", "two"])
    }

    func test_append_dropsOldestBeyondCap() {
        let store = SyncLogStore(url: url)
        for index in 0..<(SyncLogStore.maxEntries + 5) { store.append("m\(index)") }
        let messages = store.entries().map(\.message)
        XCTAssertEqual(messages.count, SyncLogStore.maxEntries)
        XCTAssertEqual(messages.first, "m5")
        XCTAssertEqual(messages.last, "m\(SyncLogStore.maxEntries + 4)")
    }

    func test_clear_emptiesLog() {
        let store = SyncLogStore(url: url)
        store.append("x")
        store.clear()
        XCTAssertTrue(store.entries().isEmpty)
    }

    func test_corruptFile_readsAsEmptyAndRecovers() throws {
        try Data("not json".utf8).write(to: url)
        let store = SyncLogStore(url: url)
        XCTAssertTrue(store.entries().isEmpty)
        store.append("fresh")
        XCTAssertEqual(store.entries().map(\.message), ["fresh"])
    }

    func test_append_createsMissingDirectory() {
        let nested = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync-log-dir-\(UUID().uuidString)")
            .appendingPathComponent("sync-log.json")
        defer { try? FileManager.default.removeItem(at: nested.deletingLastPathComponent()) }
        let store = SyncLogStore(url: nested)
        store.append("hello")
        XCTAssertEqual(store.entries().map(\.message), ["hello"])
    }

    func test_lastSyncStore_roundTrips() {
        let defaults = UserDefaults(suiteName: "last-sync-\(UUID().uuidString)")!
        let store = LastSyncStore(defaults: defaults)
        XCTAssertNil(store.lastSuccessfulSync)
        let date = Date(timeIntervalSince1970: 1_000_000)
        store.setLastSuccessfulSync(date)
        XCTAssertEqual(LastSyncStore(defaults: defaults).lastSuccessfulSync, date)
    }

    func test_formatter_oneLinePerEntry() {
        let entries = [SyncLogEntry(date: Date(timeIntervalSince1970: 0), message: "a"), SyncLogEntry(date: Date(timeIntervalSince1970: 60), message: "b")]
        let lines = SyncLogFormatter.text(entries).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasSuffix(" a"))
        XCTAssertTrue(lines[1].hasSuffix(" b"))
    }
}

final class InMemoryLastSync: LastSyncStoring, @unchecked Sendable {
    private(set) var lastSuccessfulSync: Date?
    func setLastSuccessfulSync(_ date: Date) { lastSuccessfulSync = date }
}
