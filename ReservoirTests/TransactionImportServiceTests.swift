import XCTest
import SwiftData
import SwiftUI
@testable import Reservoir

/// Covers `TransactionImportService`'s orchestration logic against a real in-memory
/// `ModelContainer` (see `ModelPersistenceTests.swift` for the setup precedent) and a
/// scripted `URLProtocol` standing in for `/transactions/sync` (see
/// `PlaidServiceLiveTests.swift`'s `SuccessfulExchangeURLProtocol` for the pattern).
@MainActor
final class TransactionImportServiceTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        let schema = Schema(versionedSchema: SchemaV9.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, migrationPlan: ReservoirMigrationPlan.self, configurations: [configuration])
        context = ModelContext(container)
        ScriptedSyncURLProtocol.reset()
        SlowSyncURLProtocol.reset()
    }

    override func tearDownWithError() throws {
        context = nil
        container = nil
        ScriptedSyncURLProtocol.reset()
        SlowSyncURLProtocol.reset()
    }

    // MARK: - Test doubles

    /// Returns each queued response in order for successive `/transactions/sync` calls
    /// (one call per page); the last queued response repeats if more calls happen than
    /// responses were scripted.
    private final class ScriptedSyncURLProtocol: URLProtocol {
        nonisolated(unsafe) static var responses: [Data] = []
        /// Status code for each scripted response — defaults to 200 for every existing
        /// test that never touches this. `reservoir-adq.6.5`'s item-error tests script a
        /// 400 alongside an `ITEM_LOGIN_REQUIRED` body to exercise
        /// `TransactionImportService.post(_:body:baseURL:)`'s non-2xx body-decoding path.
        nonisolated(unsafe) static var statusCodes: [Int] = []
        nonisolated(unsafe) static var callCount = 0

        static func reset() {
            responses = []
            statusCodes = []
            callCount = 0
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let index = min(Self.callCount, max(Self.responses.count - 1, 0))
            Self.callCount += 1
            let body = Self.responses.isEmpty ? Data() : Self.responses[index]
            let statusCode = Self.statusCodes.isEmpty ? 200 : Self.statusCodes[min(index, Self.statusCodes.count - 1)]
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://sandbox.plaid.com")!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    /// Fails every request outright with a genuine `URLError` (rather than an HTTP
    /// response) — stands in for a real network/transport failure (no connectivity, DNS
    /// failure, etc.), distinct from `ScriptedSyncURLProtocol`'s HTTP-level failures.
    /// Backs `reservoir-adq.6.5`'s "transient/network error must not set needsAttention"
    /// coverage — the acceptance criterion explicitly calls for this alongside the
    /// existing malformed-JSON-body coverage.
    private final class NetworkFailureURLProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        }

        override func stopLoading() {}
    }

    private func makeNetworkFailureURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NetworkFailureURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    /// Reports a fixed access token as already stored — backs the
    /// `PlaidServiceLive.startRelink` integration test below, which needs
    /// `keychain.read(for:)` to succeed before `startRelink` attempts its network call.
    private final class StubKeychainWithAccessToken: KeychainServicing, @unchecked Sendable {
        func save(_ value: String, for key: String) async throws {}
        func read(for key: String) async throws -> String? { "access-sandbox-relink-test" }
        func delete(for key: String) async throws {}
    }

    /// Answers any request (`/link/token/create` included) with a fixed successful
    /// `{"link_token": ...}` body — backs the same integration test, which only needs
    /// `startRelink(for:)`'s token-creation call to succeed, not to inspect its body (that's
    /// covered separately in `PlaidServiceLiveTests`).
    private final class LinkTokenURLProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let body = Data(#"{"link_token": "link-sandbox-relink-integration-test"}"#.utf8)
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://sandbox.plaid.com")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func makeLinkTokenURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LinkTokenURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private final class CancelledURLProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
        }
        override func stopLoading() {}
    }

    private func makeCancelledURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CancelledURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeScriptedURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptedSyncURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    /// Stands in for `/transactions/sync` but blocks `startLoading()` on `gate` until the
    /// test signals it — lets a test hold `runImport()` mid-flight (`isImporting == true`)
    /// for as long as needed, to exercise the `handleScenePhaseTransition`/`isImporting`
    /// interaction (code review finding: a foreground trigger landing while another import
    /// is already in flight must not silently consume `hasBackgroundedSinceActive`).
    private final class SlowSyncURLProtocol: URLProtocol {
        nonisolated(unsafe) static var gate = DispatchSemaphore(value: 0)
        nonisolated(unsafe) static var response = Data()
        nonisolated(unsafe) static var callCount = 0

        static func reset() {
            gate = DispatchSemaphore(value: 0)
            response = Data()
            callCount = 0
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            // Bounded, not `.wait()` with no timeout: `URLSessionConfiguration.ephemeral`
            // sessions share a limited, process-wide loading-thread pool, so a genuinely
            // unbounded wait here (from a test bug that forgets to signal) leaks a blocked
            // thread that starves every *other* test's network calls in this file, not
            // just this one -- exactly what happened when this test originally only
            // signaled the gate once but triggered two real network calls (code review
            // finding: the retry call blocked forever on an already-exhausted semaphore).
            _ = Self.gate.wait(timeout: .now() + 5)
            Self.callCount += 1
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://sandbox.plaid.com")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.response)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func makeSlowURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SlowSyncURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    /// The itemID every test below implicitly imports against, via `makeSUT`'s default
    /// `linkedItemStore` — `runImport()` now needs a known linked item's ID to scope its
    /// Keychain read and sync-cursor storage (reservoir-loc.1), so a `StubLinkedItemStore`
    /// with nothing in it would make every test below hit the "no linked item" no-op path
    /// even though `StubKeychainWithToken` (which ignores the key it's asked for) implies
    /// one is linked. Tests that need to assert against a specific cursor entry use this
    /// same constant rather than a magic string.
    private static let defaultItemID = "item-1"

    private func makeSUT(
        keychain: KeychainServicing = StubKeychainWithToken(),
        cursorStore: PlaidSyncCursorStoring = StubCursorStore(),
        linkedItemStore: LinkedItemStoring = StubLinkedItemStore(
            initial: LinkedItem(itemID: TransactionImportServiceTests.defaultItemID, institutionName: "Test Bank", linkedAt: .now)
        ),
        linkedAccountStore: LinkedAccountStoring = StubLinkedAccountStore(),
        backfillStore: PlaidAccountBackfillStoring = StubAccountBackfillStore(defaultComplete: true),
        urlSession: URLSession? = nil,
        postLinkBackoff: [Duration] = [.seconds(1), .seconds(2), .seconds(3)],
        sleep: @escaping @MainActor (Duration) async throws -> Void = { _ in }
    ) -> TransactionImportService {
        TransactionImportService(
            modelContext: context,
            keychain: keychain,
            urlSession: urlSession ?? makeScriptedURLSession(),
            environmentStore: StubEnvironmentStore(.sandbox),
            cursorStore: cursorStore,
            linkedItemStore: linkedItemStore,
            linkedAccountStore: linkedAccountStore,
            backfillStore: backfillStore,
            syncLog: InMemorySyncLog(),
            lastSyncStore: InMemoryLastSync(),
            postLinkBackoff: postLinkBackoff,
            sleep: sleep
        )
    }

    // MARK: - removeLocalData (reservoir-wo1)

    private func seedUnlinkFixture() throws -> (goal: SavingsGoal, keep: [SpendTransaction], doomed: [SpendTransaction]) {
        let goal = makeGoal()
        context.insert(goal)
        let doomed = [
            SpendTransaction(amount: 5, date: .now, merchantName: "A", type: .variable, entryMethod: .imported, plaidTransactionID: "p1", plaidItemID: "item-1", savingsGoal: goal),
            SpendTransaction(amount: 6, date: .now, merchantName: "B", type: .variable, entryMethod: .imported, plaidTransactionID: "p2", plaidItemID: "item-1")
        ]
        let keep = [
            SpendTransaction(amount: 7, date: .now, merchantName: "Other item", type: .variable, entryMethod: .imported, plaidTransactionID: "p3", plaidItemID: "item-2", savingsGoal: goal),
            SpendTransaction(amount: 8, date: .now, merchantName: "Manual", type: .variable, entryMethod: .manual, savingsGoal: goal),
            SpendTransaction(amount: 9, date: .now, merchantName: "Merged", type: .variable, entryMethod: .imported, plaidTransactionID: "p4", plaidItemID: "item-1", savingsGoal: goal, wasMergedFromManual: true)
        ]
        (doomed + keep).forEach(context.insert)
        try context.save()
        return (goal, keep, doomed)
    }

    func test_removeLocalData_delete_removesOnlyThatItemsPureImportedRows() throws {
        let fixture = try seedUnlinkFixture()
        let sut = makeSUT()

        let failure = sut.removeLocalData(forItemID: "item-1", deleteTransactions: true)

        XCTAssertNil(failure)
        let remaining = Set(try context.fetch(FetchDescriptor<SpendTransaction>()).map(\.merchantName))
        XCTAssertEqual(remaining, ["Other item", "Manual", "Merged"])
        XCTAssertEqual(Set(fixture.goal.transactions.map(\.merchantName)), ["Other item", "Manual", "Merged"], "goal's transaction list (and thus any derived totals) must drop the deleted rows.")
    }

    func test_removeLocalData_keep_leavesAllTransactions() throws {
        _ = try seedUnlinkFixture()
        let sut = makeSUT()

        XCTAssertNil(sut.removeLocalData(forItemID: "item-1", deleteTransactions: false))

        XCTAssertEqual(try context.fetch(FetchDescriptor<SpendTransaction>()).count, 5)
    }

    func test_removeLocalData_discardsOnlyThatItemsPendingMerges_bothChoices() throws {
        for deleteTransactions in [true, false] {
            let manual1 = SpendTransaction(amount: 3, date: .now, merchantName: "M1", type: .variable, entryMethod: .manual)
            let manual2 = SpendTransaction(amount: 4, date: .now, merchantName: "M2", type: .variable, entryMethod: .manual)
            context.insert(manual1)
            context.insert(manual2)
            context.insert(PendingTransactionMerge(plaidTransactionID: "q1", incomingAmount: 3, incomingDate: .now, incomingMerchantName: "M1", manualTransaction: manual1, plaidItemID: "item-1"))
            context.insert(PendingTransactionMerge(plaidTransactionID: "q2", incomingAmount: 4, incomingDate: .now, incomingMerchantName: "M2", manualTransaction: manual2, plaidItemID: "item-2"))
            try context.save()
            let sut = makeSUT()
            XCTAssertEqual(sut.mergeQueue.count, 2, "sanity: both decisions hydrated.")

            XCTAssertNil(sut.removeLocalData(forItemID: "item-1", deleteTransactions: deleteTransactions))

            XCTAssertEqual(sut.mergeQueue.map(\.id), ["q2"])
            XCTAssertEqual(try context.fetch(FetchDescriptor<PendingTransactionMerge>()).map(\.plaidTransactionID), ["q2"])
            XCTAssertEqual(try context.fetch(FetchDescriptor<SpendTransaction>()).count, 2, "manual rows are never deleted.")

            for r in try context.fetch(FetchDescriptor<PendingTransactionMerge>()) { context.delete(r) }
            for t in try context.fetch(FetchDescriptor<SpendTransaction>()) { context.delete(t) }
            try context.save()
        }
    }

    func test_removeLocalData_saveFailure_returnsMessageAndKeepsRows() throws {
        let (readOnlyContext, _) = try makeReadOnlyContext()
        // Unrelated unsaved insert guarantees the context has pending changes, so the
        // (read-only) save genuinely throws even if the scoped delete nets out to nothing.
        readOnlyContext.insert(SpendTransaction(amount: 1, date: .now, merchantName: "Pending", type: .variable, entryMethod: .manual))
        readOnlyContext.insert(SpendTransaction(amount: 5, date: .now, merchantName: "A", type: .variable, entryMethod: .imported, plaidTransactionID: "p1", plaidItemID: "item-1"))
        let sut = TransactionImportService(
            modelContext: readOnlyContext,
            keychain: StubKeychainWithToken(),
            urlSession: makeScriptedURLSession(),
            environmentStore: StubEnvironmentStore(.sandbox),
            cursorStore: StubCursorStore(),
            linkedItemStore: StubLinkedItemStore(initial: LinkedItem(itemID: "item-1", institutionName: "B", linkedAt: .now)),
            linkedAccountStore: StubLinkedAccountStore(),
            backfillStore: StubAccountBackfillStore(defaultComplete: true),
            syncLog: InMemorySyncLog(),
            lastSyncStore: InMemoryLastSync()
        )

        let failure = sut.removeLocalData(forItemID: "item-1", deleteTransactions: true)

        XCTAssertNotNil(failure)
    }

    // MARK: - removeOrphanedLocalData (reservoir-xxm)

    private func makeLinkedStore(_ ids: [String]) -> StubLinkedItemStore {
        let store = StubLinkedItemStore()
        for id in ids { store.save(LinkedItem(itemID: id, institutionName: id, linkedAt: .now)) }
        return store
    }

    private func imported(_ name: String, item: String?, goal: SavingsGoal? = nil, merged: Bool = false) -> SpendTransaction {
        SpendTransaction(amount: 5, date: .now, merchantName: name, type: .variable, entryMethod: .imported, plaidTransactionID: "id-\(name)", plaidItemID: item, savingsGoal: goal, wasMergedFromManual: merged)
    }

    func test_removeOrphaned_removesOnlyUnlinkedImportedRows_keepsEverythingElse() throws {
        let goal = makeGoal()
        context.insert(goal)
        [
            imported("linked", item: "live"),
            imported("orphanA", item: "gone-1", goal: goal),
            imported("orphanB", item: "gone-2"),
            imported("mergedOrphan", item: "gone-1", merged: true),
            imported("legacyNil", item: nil),
            imported("legacyEmpty", item: ""),
            SpendTransaction(amount: 1, date: .now, merchantName: "manual", type: .variable, entryMethod: .manual, savingsGoal: goal)
        ].forEach(context.insert)
        try context.save()
        let sut = makeSUT(linkedItemStore: makeLinkedStore(["live"]))
        XCTAssertEqual(sut.orphanedDataSummary().transactionCount, 2)

        XCTAssertNil(sut.removeOrphanedLocalData())

        let remaining = Set(try context.fetch(FetchDescriptor<SpendTransaction>()).map(\.merchantName))
        XCTAssertEqual(remaining, ["linked", "mergedOrphan", "legacyNil", "legacyEmpty", "manual"])
        XCTAssertEqual(Set(goal.transactions.map(\.merchantName)), ["manual"])
        XCTAssertTrue(sut.orphanedDataSummary().isEmpty)
    }

    func test_removeOrphaned_clearsOnlyNonLinkedCursors_acrossEnvironments() throws {
        let cursors = StubCursorStore()
        cursors.setCursor("a", for: .sandbox, itemID: "live")
        cursors.setCursor("b", for: .sandbox, itemID: "gone-1")
        cursors.setCursor("c", for: .production, itemID: "gone-2")
        cursors.setCursor("d", for: .production, itemID: "live")
        let sut = makeSUT(cursorStore: cursors, linkedItemStore: makeLinkedStore(["live"]))
        XCTAssertEqual(sut.orphanedDataSummary().cursorCount, 2)

        XCTAssertNil(sut.removeOrphanedLocalData())

        XCTAssertNil(cursors.cursor(for: .sandbox, itemID: "gone-1"))
        XCTAssertNil(cursors.cursor(for: .production, itemID: "gone-2"))
        XCTAssertEqual(cursors.cursor(for: .sandbox, itemID: "live"), "a")
        XCTAssertEqual(cursors.cursor(for: .production, itemID: "live"), "d")
    }

    func test_removeOrphaned_discardsOnlyUnlinkedPendingMerges_andPrunesQueue() throws {
        let manual1 = SpendTransaction(amount: 3, date: .now, merchantName: "M1", type: .variable, entryMethod: .manual)
        let manual2 = SpendTransaction(amount: 4, date: .now, merchantName: "M2", type: .variable, entryMethod: .manual)
        let manual3 = SpendTransaction(amount: 5, date: .now, merchantName: "M3", type: .variable, entryMethod: .manual)
        [manual1, manual2, manual3].forEach(context.insert)
        context.insert(PendingTransactionMerge(plaidTransactionID: "q1", incomingAmount: 3, incomingDate: .now, incomingMerchantName: "M1", manualTransaction: manual1, plaidItemID: "gone-1"))
        context.insert(PendingTransactionMerge(plaidTransactionID: "q2", incomingAmount: 4, incomingDate: .now, incomingMerchantName: "M2", manualTransaction: manual2, plaidItemID: "live"))
        context.insert(PendingTransactionMerge(plaidTransactionID: "q3", incomingAmount: 5, incomingDate: .now, incomingMerchantName: "M3", manualTransaction: manual3, plaidItemID: nil))
        try context.save()
        let sut = makeSUT(linkedItemStore: makeLinkedStore(["live"]))
        XCTAssertEqual(sut.mergeQueue.count, 3)

        XCTAssertNil(sut.removeOrphanedLocalData())

        XCTAssertEqual(Set(sut.mergeQueue.map(\.id)), ["q2", "q3"])
        XCTAssertEqual(Set(try context.fetch(FetchDescriptor<PendingTransactionMerge>()).map(\.plaidTransactionID)), ["q2", "q3"])
        XCTAssertEqual(try context.fetch(FetchDescriptor<SpendTransaction>()).count, 3, "manual rows are never deleted.")
    }

    func test_removeOrphaned_noLinkedItems_treatsEveryTaggedImportAsOrphaned_butNotNilID() throws {
        [imported("tagged", item: "gone-1"), imported("legacy", item: nil)].forEach(context.insert)
        try context.save()
        let sut = makeSUT(linkedItemStore: StubLinkedItemStore())

        XCTAssertNil(sut.removeOrphanedLocalData())

        XCTAssertEqual(try context.fetch(FetchDescriptor<SpendTransaction>()).map(\.merchantName), ["legacy"])
    }

    func test_removeOrphaned_saveFailure_returnsMessage_keepsCursorsAndQueue() throws {
        let (readOnlyContext, _) = try makeReadOnlyContext()
        readOnlyContext.insert(SpendTransaction(amount: 1, date: .now, merchantName: "Pending", type: .variable, entryMethod: .manual))
        let goal = makeGoal()
        readOnlyContext.insert(goal)
        readOnlyContext.insert(imported("orphan", item: "gone-1", goal: goal))
        let cursors = StubCursorStore()
        cursors.setCursor("b", for: .sandbox, itemID: "gone-1")
        let sut = TransactionImportService(
            modelContext: readOnlyContext,
            keychain: StubKeychainWithToken(),
            urlSession: makeScriptedURLSession(),
            environmentStore: StubEnvironmentStore(.sandbox),
            cursorStore: cursors,
            linkedItemStore: StubLinkedItemStore(),
            linkedAccountStore: StubLinkedAccountStore(),
            backfillStore: StubAccountBackfillStore(defaultComplete: true),
            syncLog: InMemorySyncLog(),
            lastSyncStore: InMemoryLastSync()
        )

        XCTAssertNotNil(sut.removeOrphanedLocalData())

        XCTAssertEqual(cursors.cursor(for: .sandbox, itemID: "gone-1"), "b", "cursors must survive a failed save so a retry still finds them.")
        let rows = try readOnlyContext.fetch(FetchDescriptor<SpendTransaction>()).filter { $0.merchantName == "orphan" }
        XCTAssertEqual(rows.count, 1, "rollback must restore the deleted row.")
        XCTAssertNotNil(rows.first?.savingsGoal, "rollback must restore the goal link.")
    }

    func test_removeOrphaned_whileImportInFlight_noOpsWithMessage() async throws {
        SlowSyncURLProtocol.response = syncResponse(nextCursor: "c")
        context.insert(imported("orphan", item: "gone-1"))
        try context.save()
        let sut = makeSUT(urlSession: makeSlowURLSession())
        let inFlight = Task { await sut.runImport() }
        var waited = 0
        while !sut.isSyncActive, waited < 50 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            waited += 1
        }
        XCTAssertTrue(sut.isSyncActive)

        XCTAssertNotNil(sut.removeOrphanedLocalData())
        XCTAssertEqual(try context.fetch(FetchDescriptor<SpendTransaction>()).count, 1)

        SlowSyncURLProtocol.gate.signal()
        await inFlight.value
        XCTAssertFalse(sut.isSyncActive)
        XCTAssertNil(sut.removeOrphanedLocalData())
        XCTAssertEqual(try context.fetch(FetchDescriptor<SpendTransaction>()).count, 0)
    }

    // MARK: - JSON fixtures

    private func transactionJSON(id: String, amount: Decimal, date: String = "2026-07-10", merchantName: String? = "Coffee Shop", name: String = "COFFEE SHOP") -> String {
        let merchantField = merchantName.map { "\"\($0)\"" } ?? "null"
        return #"{"transaction_id": "\#(id)", "amount": \#(amount), "date": "\#(date)", "merchant_name": \#(merchantField), "name": "\#(name)"}"#
    }

    private func removedJSON(id: String) -> String {
        #"{"transaction_id": "\#(id)"}"#
    }

    /// The `Date` corresponding to `transactionJSON`'s default `date: "2026-07-10"` —
    /// dedup-match tests need their manual fixture's `date` to land on the exact same
    /// calendar day as the scripted incoming transaction, not just "whatever `.now`
    /// happens to be" (which was a real bug caught here: `.now` at test-run time and a
    /// hardcoded JSON date string are almost never the same day).
    private var matchingFixtureDate: Date {
        // Built the same way `PlaidTransactionMapper.localDate(from:calendar:)` builds
        // its `Date` (local calendar-day components, not a UTC-anchored formatter) —
        // see that type's doc comment for why a UTC anchor breaks dedup matching.
        var components = DateComponents()
        components.year = 2026
        components.month = 7
        components.day = 10
        return Calendar.current.date(from: components)!
    }

    private func syncResponse(added: [String] = [], modified: [String] = [], removed: [String] = [], nextCursor: String, hasMore: Bool = false, status: String? = nil) -> Data {
        let statusField = status.map { #", "transactions_update_status": "\#($0)""# } ?? ""
        let json = """
        {"added": [\(added.joined(separator: ","))], "modified": [\(modified.joined(separator: ","))], "removed": [\(removed.joined(separator: ","))], "next_cursor": "\(nextCursor)", "has_more": \(hasMore)\(statusField)}
        """
        return Data(json.utf8)
    }

    /// Plaid's documented non-2xx error-body shape (reservoir-adq.6.5) — used with
    /// `ScriptedSyncURLProtocol.statusCodes` set to a matching non-2xx status.
    private func itemErrorResponse(errorType: String = "ITEM_ERROR", errorCode: String) -> Data {
        Data(#"{"error_type": "\#(errorType)", "error_code": "\#(errorCode)", "error_message": "test"}"#.utf8)
    }

    // MARK: - Fixtures

    private func makeGoal(dailyBase: Decimal = 30) -> SavingsGoal {
        SavingsGoal(
            targetAmount: 1000,
            targetDate: Calendar.current.date(byAdding: .day, value: 30, to: .now)!,
            startDate: .now,
            startingBalance: 0,
            dailyBase: dailyBase
        )
    }

    // MARK: - No linked item

    func testRunImport_withNoStoredToken_isNoOp() async {
        let sut = makeSUT(keychain: StubKeychain())
        await sut.runImport()
        XCTAssertNil(sut.lastImportSummary)
        XCTAssertTrue(sut.mergeQueue.isEmpty)
    }

    // MARK: - Added: no dedup match -> saved as new imported transaction

    func testRunImport_addedWithNoMatch_savesNewImportedTransaction() async throws {
        ScriptedSyncURLProtocol.responses = [
            syncResponse(added: [transactionJSON(id: "plaid-1", amount: 12.50)], nextCursor: "cursor-1")
        ]
        let sut = makeSUT()

        await sut.runImport()

        let fetched = try context.fetch(FetchDescriptor<SpendTransaction>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.entryMethod, .imported)
        XCTAssertEqual(fetched.first?.plaidTransactionID, "plaid-1")
        XCTAssertEqual(fetched.first?.amount, 12.50)
        XCTAssertEqual(sut.lastImportSummary?.added, 1)
        XCTAssertEqual(fetched.first?.plaidItemID, Self.defaultItemID, "reservoir-loc.1: a freshly imported row must record which linked item it came from.")
    }

    // MARK: - Added: dedup match -> queued, not saved

    func testRunImport_addedWithDedupMatch_queuesMergeDecision_doesNotSaveNewRow() async throws {
        let manual = SpendTransaction(amount: 12.50, date: matchingFixtureDate, merchantName: "Coffee Shop", type: .variable, entryMethod: .manual)
        context.insert(manual)
        try context.save()

        ScriptedSyncURLProtocol.responses = [
            syncResponse(added: [transactionJSON(id: "plaid-1", amount: 12.50)], nextCursor: "cursor-1")
        ]
        let sut = makeSUT()

        await sut.runImport()

        XCTAssertEqual(sut.mergeQueue.count, 1)
        XCTAssertEqual(sut.pendingMergeDecision?.manualTransaction.persistentModelID, manual.persistentModelID)
        let fetched = try context.fetch(FetchDescriptor<SpendTransaction>())
        XCTAssertEqual(fetched.count, 1, "No second row should be saved while a merge decision is pending.")
        XCTAssertEqual(sut.lastImportSummary?.queuedForMerge, 1)
        XCTAssertEqual(sut.lastImportSummary?.added, 0)
    }

    /// A page whose only "unhandled" item was queued for merge (not saved, but also not
    /// a failure) must still advance the cursor — Plaid won't redeliver an
    /// already-acknowledged `added` item once the cursor moves past it.
    func testRunImport_pageWithOnlyQueuedMergeItem_stillAdvancesCursor() async throws {
        let manual = SpendTransaction(amount: 12.50, date: matchingFixtureDate, merchantName: "Coffee Shop", type: .variable, entryMethod: .manual)
        context.insert(manual)
        try context.save()

        ScriptedSyncURLProtocol.responses = [
            syncResponse(added: [transactionJSON(id: "plaid-1", amount: 12.50)], nextCursor: "cursor-after-queue")
        ]
        let cursorStore = StubCursorStore()
        let sut = makeSUT(cursorStore: cursorStore)

        await sut.runImport()

        XCTAssertEqual(sut.mergeQueue.count, 1, "sanity check: the item must actually have been queued for merge, not saved outright.")
        XCTAssertEqual(cursorStore.cursor(for: .sandbox, itemID: Self.defaultItemID), "cursor-after-queue")
    }

    // MARK: - Merge-decision persistence (review findings 2+5 -- see SchemaV5's doc comment)

    /// A pending decision must survive process death: `mergeQueue` was previously
    /// in-memory only, so a killed app or deallocated `TransactionImportService`
    /// instance lost any unresolved decision for good, since Plaid won't redeliver an
    /// already-acknowledged `added` item once the cursor moves past its page. Proves the
    /// fix by constructing a brand-new `TransactionImportService` against the *same*
    /// `ModelContext` (simulating an app relaunch) with no in-memory knowledge of the
    /// first instance's `mergeQueue`, and asserting the decision is recovered from the
    /// persisted `PendingTransactionMerge` row.
    func testPendingMergeDecision_survivesFreshServiceInstance_simulatingRelaunch() async throws {
        let manual = SpendTransaction(amount: 12.50, date: matchingFixtureDate, merchantName: "Coffee Shop", type: .variable, entryMethod: .manual)
        context.insert(manual)
        try context.save()

        ScriptedSyncURLProtocol.responses = [
            syncResponse(added: [transactionJSON(id: "plaid-1", amount: 12.50)], nextCursor: "cursor-1")
        ]
        let sut = makeSUT()
        await sut.runImport()
        XCTAssertEqual(sut.mergeQueue.count, 1, "sanity check: the item must actually have been queued for merge.")

        let relaunchedSUT = makeSUT()

        XCTAssertEqual(relaunchedSUT.mergeQueue.count, 1, "A pending decision must be recoverable on next launch, not lost when the owning service instance is deallocated.")
        XCTAssertEqual(relaunchedSUT.pendingMergeDecision?.manualTransaction.persistentModelID, manual.persistentModelID)
        XCTAssertEqual(relaunchedSUT.pendingMergeDecision?.incoming.plaidTransactionID, "plaid-1")
    }

    /// A second, independent sync run (e.g. a fresh instance after relaunch) must not
    /// queue a duplicate decision against a manual transaction that already has one
    /// pending -- the manual transaction is still `entryMethod == .manual` (only
    /// resolving the decision changes that), so without excluding already-queued
    /// candidates it would dedup-match again against a *different* incoming transaction.
    func testRunImport_secondIndependentRun_doesNotDoubleQueueSameManualTransaction() async throws {
        let manual = SpendTransaction(amount: 12.50, date: matchingFixtureDate, merchantName: "Coffee Shop", type: .variable, entryMethod: .manual)
        context.insert(manual)
        try context.save()

        ScriptedSyncURLProtocol.responses = [
            syncResponse(added: [transactionJSON(id: "plaid-1", amount: 12.50)], nextCursor: "cursor-1")
        ]
        let sut = makeSUT()
        await sut.runImport()
        XCTAssertEqual(sut.mergeQueue.count, 1, "sanity check: the item must actually have been queued for merge.")

        // A brand-new service instance (simulating a second, independent sync run) sees
        // another incoming transaction that would also dedup-match the same still-
        // unresolved manual transaction.
        ScriptedSyncURLProtocol.responses = [
            syncResponse(added: [transactionJSON(id: "plaid-2", amount: 12.50)], nextCursor: "cursor-2")
        ]
        let secondSUT = makeSUT()
        await secondSUT.runImport()

        XCTAssertEqual(secondSUT.mergeQueue.count, 1, "The manual transaction already has a pending decision -- a second sync run must not queue a duplicate for it.")
        XCTAssertEqual(secondSUT.mergeQueue.first?.incoming.plaidTransactionID, "plaid-1", "The original decision must remain untouched.")
        let fetched = try context.fetch(FetchDescriptor<SpendTransaction>())
        XCTAssertEqual(fetched.count, 2, "manual (untouched, still pending) + plaid-2 saved directly as a new import (no eligible candidate to match against).")
        XCTAssertNotNil(fetched.first { $0.plaidTransactionID == "plaid-2" })
    }

    // MARK: - resolveMergeDecision(.merge)

    func testResolveMergeDecision_merge_updatesManualEntryInPlace_doesNotAddSecondRow() async throws {
        // Deliberately a case-only difference from the incoming transaction's merchant
        // name ("coffee shop" vs "Coffee Shop") — dedup matching is case-insensitive
        // exact (no fuzzy matching per PROJECT_SPEC), so this still counts as a match,
        // and lets this test demonstrate "Plaid wins" by asserting the merged row picks
        // up Plaid's exact casing.
        let manual = SpendTransaction(
            amount: 12.49, date: matchingFixtureDate, merchantName: "coffee shop", type: .fixed, entryMethod: .manual, isManualOverride: true
        )
        context.insert(manual)
        try context.save()

        ScriptedSyncURLProtocol.responses = [
            syncResponse(added: [transactionJSON(id: "plaid-1", amount: 12.49, merchantName: "Coffee Shop")], nextCursor: "cursor-1")
        ]
        let sut = makeSUT()
        await sut.runImport()
        XCTAssertEqual(sut.mergeQueue.count, 1)

        sut.resolveMergeDecision(.merge)

        let fetched = try context.fetch(FetchDescriptor<SpendTransaction>())
        XCTAssertEqual(fetched.count, 1, "Merge must not create a second row.")
        let merged = try XCTUnwrap(fetched.first)
        XCTAssertEqual(merged.merchantName, "Coffee Shop")
        XCTAssertEqual(merged.entryMethod, .imported)
        XCTAssertEqual(merged.plaidTransactionID, "plaid-1")
        XCTAssertTrue(merged.wasMergedFromManual)
        XCTAssertEqual(merged.type, .fixed, "type must be preserved from the manual entry.")
        XCTAssertTrue(merged.isManualOverride, "isManualOverride must be preserved from the manual entry.")
        XCTAssertTrue(sut.mergeQueue.isEmpty)
    }

    // MARK: - resolveMergeDecision(.keepBoth)

    func testResolveMergeDecision_keepBoth_leavesManualUntouched_savesNewRow() async throws {
        let manual = SpendTransaction(amount: 12.50, date: matchingFixtureDate, merchantName: "Coffee Shop", type: .variable, entryMethod: .manual)
        context.insert(manual)
        try context.save()

        ScriptedSyncURLProtocol.responses = [
            syncResponse(added: [transactionJSON(id: "plaid-1", amount: 12.50)], nextCursor: "cursor-1")
        ]
        let sut = makeSUT()
        await sut.runImport()
        XCTAssertEqual(sut.mergeQueue.count, 1, "sanity check: the item must actually have been queued for merge.")

        sut.resolveMergeDecision(.keepBoth)

        let fetched = try context.fetch(FetchDescriptor<SpendTransaction>())
        XCTAssertEqual(fetched.count, 2)
        let originalManual = fetched.first { $0.persistentModelID == manual.persistentModelID }
        XCTAssertEqual(originalManual?.entryMethod, .manual)
        XCTAssertNil(originalManual?.plaidTransactionID)
        let newImported = fetched.first { $0.plaidTransactionID == "plaid-1" }
        XCTAssertEqual(newImported?.entryMethod, .imported)
        XCTAssertTrue(sut.mergeQueue.isEmpty)
    }

    // MARK: - MerchantMatcher application at import

    func testRunImport_matchingMerchantRule_setsType() async throws {
        context.insert(MerchantRule(merchantName: "Coffee Shop", type: .fixed))
        try context.save()

        ScriptedSyncURLProtocol.responses = [
            syncResponse(added: [transactionJSON(id: "plaid-1", amount: 12.50, merchantName: "Coffee Shop")], nextCursor: "cursor-1")
        ]
        let sut = makeSUT()
        await sut.runImport()

        let fetched = try context.fetch(FetchDescriptor<SpendTransaction>())
        XCTAssertEqual(fetched.first?.type, .fixed)
        XCTAssertEqual(fetched.first?.isManualOverride, false)
    }

    func testRunImport_noMatchingMerchantRule_defaultsToVariable() async throws {
        ScriptedSyncURLProtocol.responses = [
            syncResponse(added: [transactionJSON(id: "plaid-1", amount: 12.50, merchantName: "Unknown Merchant")], nextCursor: "cursor-1")
        ]
        let sut = makeSUT()
        await sut.runImport()

        let fetched = try context.fetch(FetchDescriptor<SpendTransaction>())
        XCTAssertEqual(fetched.first?.type, .variable)
        XCTAssertEqual(fetched.first?.isManualOverride, false)
    }

    // MARK: - Goal attribution (reservoir-loc.2: account-aware, not goal-count-driven)
    //
    // Import-time attribution no longer follows
    // `TransactionEntryValidator.goalAttributionRequirement(activeGoals:)`'s
    // auto-select/no-active-goals/explicit-choice policy (that stays exactly as-is for
    // manual entry — see `TransactionEntryValidatorTests`). Instead, an imported
    // transaction attributes to whichever goal `GoalAccountAssociationService` reports as
    // associated with the transaction's `sourceItemID`, full stop — irrelevant how many
    // other goals exist.

    func testRunImport_zeroGoalsAtAll_savesUnattributed() async throws {
        ScriptedSyncURLProtocol.responses = [
            syncResponse(added: [transactionJSON(id: "plaid-1", amount: 12.50)], nextCursor: "cursor-1")
        ]
        let sut = makeSUT()
        await sut.runImport()

        let fetched = try context.fetch(FetchDescriptor<SpendTransaction>())
        XCTAssertNil(fetched.first?.savingsGoal)
    }

    /// A goal associated with the importing item attributes the transaction — even with a
    /// second, unrelated goal also in play, unlike the old goal-count-driven policy where
    /// a second active goal would have forced "explicit choice required" (unattributed at
    /// import time).
    func testRunImport_goalAssociatedWithSourceItem_attributes_regardlessOfOtherGoalCount() async throws {
        let associatedGoal = makeGoal()
        associatedGoal.associatedItemIDs = [Self.defaultItemID]
        let unrelatedGoal = makeGoal()
        context.insert(associatedGoal)
        context.insert(unrelatedGoal)
        try context.save()

        ScriptedSyncURLProtocol.responses = [
            syncResponse(added: [transactionJSON(id: "plaid-1", amount: 12.50)], nextCursor: "cursor-1")
        ]
        let sut = makeSUT()
        await sut.runImport()

        let fetched = try context.fetch(FetchDescriptor<SpendTransaction>())
        XCTAssertEqual(
            fetched.first?.savingsGoal?.persistentModelID, associatedGoal.persistentModelID,
            "must attribute to the goal associated with the importing item, not the unrelated goal, and not fall back to 'unattributed' just because a second goal exists."
        )
    }

    /// Exactly one goal exists (the old policy's auto-select case), but it isn't
    /// associated with the importing item — must stay unattributed. Proves attribution is
    /// no longer goal-count-driven at all: the old policy would have auto-selected this
    /// goal purely because it's the only one.
    func testRunImport_noGoalAssociatedWithSourceItem_savesUnattributed_evenWithExactlyOneGoal() async throws {
        let unrelatedGoal = makeGoal()
        unrelatedGoal.associatedItemIDs = ["some-other-item"]
        context.insert(unrelatedGoal)
        try context.save()

        ScriptedSyncURLProtocol.responses = [
            syncResponse(added: [transactionJSON(id: "plaid-1", amount: 12.50)], nextCursor: "cursor-1")
        ]
        let sut = makeSUT()
        await sut.runImport()

        let fetched = try context.fetch(FetchDescriptor<SpendTransaction>())
        XCTAssertNil(
            fetched.first?.savingsGoal,
            "the sole goal isn't associated with the importing item, so it must not be auto-selected."
        )
    }

    // MARK: - resolveMergeDecision(.keepBoth) — account-aware attribution + plaidItemID stamping

    /// "Keep both" must apply the same account-aware attribution policy as the main
    /// `added` path, and must stamp `plaidItemID` on the new row (reservoir-loc.2's
    /// `SchemaV7` fix — previously `applyKeepBothDecision` never passed `sourceItemID`
    /// through at all, so every keep-both result's `plaidItemID` was `nil`).
    func testResolveMergeDecision_keepBoth_attributesToAssociatedGoal_andStampsPlaidItemID() async throws {
        let associatedGoal = makeGoal()
        associatedGoal.associatedItemIDs = [Self.defaultItemID]
        context.insert(associatedGoal)
        let manual = SpendTransaction(amount: 12.50, date: matchingFixtureDate, merchantName: "Coffee Shop", type: .variable, entryMethod: .manual)
        context.insert(manual)
        try context.save()

        ScriptedSyncURLProtocol.responses = [
            syncResponse(added: [transactionJSON(id: "plaid-1", amount: 12.50)], nextCursor: "cursor-1")
        ]
        let sut = makeSUT()
        await sut.runImport()
        XCTAssertEqual(sut.mergeQueue.count, 1, "sanity check: the item must actually have been queued for merge.")
        sut.resolveMergeDecision(.keepBoth)

        let fetched = try context.fetch(FetchDescriptor<SpendTransaction>())
        let newImported = try XCTUnwrap(fetched.first { $0.plaidTransactionID == "plaid-1" })
        XCTAssertEqual(newImported.savingsGoal?.persistentModelID, associatedGoal.persistentModelID)
        XCTAssertEqual(newImported.plaidItemID, Self.defaultItemID, "the keep-both result must be stamped with the item ID recovered from the persisted PendingTransactionMerge row.")
    }

    /// Companion to the above: a goal exists but isn't associated with the importing
    /// item — "Keep both" must leave the new row unattributed, same as the main `added`
    /// path would, not fall back to any goal-count-based auto-select.
    func testResolveMergeDecision_keepBoth_noAssociatedGoal_savesUnattributed() async throws {
        let unrelatedGoal = makeGoal()
        unrelatedGoal.associatedItemIDs = ["some-other-item"]
        context.insert(unrelatedGoal)
        let manual = SpendTransaction(amount: 12.50, date: matchingFixtureDate, merchantName: "Coffee Shop", type: .variable, entryMethod: .manual)
        context.insert(manual)
        try context.save()

        ScriptedSyncURLProtocol.responses = [
            syncResponse(added: [transactionJSON(id: "plaid-1", amount: 12.50)], nextCursor: "cursor-1")
        ]
        let sut = makeSUT()
        await sut.runImport()
        XCTAssertEqual(sut.mergeQueue.count, 1, "sanity check: the item must actually have been queued for merge.")
        sut.resolveMergeDecision(.keepBoth)

        let fetched = try context.fetch(FetchDescriptor<SpendTransaction>())
        let newImported = try XCTUnwrap(fetched.first { $0.plaidTransactionID == "plaid-1" })
        XCTAssertNil(newImported.savingsGoal)
        XCTAssertEqual(newImported.plaidItemID, Self.defaultItemID, "plaidItemID stamping is independent of goal attribution -- must still be recorded even with no associated goal.")
    }

    // MARK: - Multi-item import (reservoir-loc.2)

    /// Two linked items whose incoming transactions this run both dedup-match the *same*
    /// pre-existing manual transaction (identical amount/calendar-day/merchant name) —
    /// the cross-account false-merge scenario this story's dedup-fix section is about.
    /// The shared, shrinking candidate pool (not a per-item-scoped pool, and no signature
    /// change to `TransactionDedupMatcher.findMatch`) means the first item processed
    /// claims the match and removes it from the pool immediately; the second item's
    /// otherwise-identical incoming transaction finds no candidate left and is saved as
    /// its own new imported row, correctly tagged with *its own* `plaidItemID` — never
    /// merged into the first item's manual entry.
    func testRunImport_twoItems_sharedManualTransaction_firstItemClaimsMatch_secondSavesIndependently() async throws {
        let manual = SpendTransaction(amount: 12.50, date: matchingFixtureDate, merchantName: "Coffee Shop", type: .variable, entryMethod: .manual)
        context.insert(manual)
        try context.save()

        let linkedItemStore = StubLinkedItemStore(
            initial: LinkedItem(itemID: Self.defaultItemID, institutionName: "Bank One", linkedAt: .now)
        )
        linkedItemStore.save(LinkedItem(itemID: "item-2", institutionName: "Bank Two", linkedAt: .now))

        // Call order mirrors `linkedItemStore.loadAll()`'s order (insertion order for
        // this stub) -- item-1 processed first, item-2 second.
        ScriptedSyncURLProtocol.responses = [
            syncResponse(added: [transactionJSON(id: "plaid-item1-txn", amount: 12.50)], nextCursor: "cursor-item1"),
            syncResponse(added: [transactionJSON(id: "plaid-item2-txn", amount: 12.50)], nextCursor: "cursor-item2"),
        ]
        let sut = makeSUT(linkedItemStore: linkedItemStore)

        await sut.runImport()

        XCTAssertEqual(sut.mergeQueue.count, 1, "only the first item's incoming transaction should claim the shared manual candidate.")
        XCTAssertEqual(sut.mergeQueue.first?.incoming.plaidTransactionID, "plaid-item1-txn")

        let fetched = try context.fetch(FetchDescriptor<SpendTransaction>())
        // manual (still pending merge, untouched) + item-2's independently saved import.
        XCTAssertEqual(fetched.count, 2)
        let secondItemImport = try XCTUnwrap(fetched.first { $0.plaidTransactionID == "plaid-item2-txn" })
        XCTAssertEqual(secondItemImport.entryMethod, .imported)
        XCTAssertEqual(
            secondItemImport.plaidItemID, "item-2",
            "the second item's transaction must be tagged with its own item ID -- it must never be silently absorbed into item-1's manual entry."
        )
    }

    /// Same shared-manual-candidate setup as above, but with a third linked item added —
    /// proves the pool exhaustion holds across more than two competitors, not just a
    /// two-item coincidence: only the very first item to process a matching incoming
    /// transaction ever gets a merge decision queued against that manual row; every other
    /// item with an identical-signature incoming transaction saves its own independent
    /// row instead of re-matching (or double-queueing against) the same manual candidate.
    func testRunImport_threeItems_sharedManualCandidatePool_onlyFirstMatchQueued_othersSaveIndependently() async throws {
        let manual = SpendTransaction(amount: 12.50, date: matchingFixtureDate, merchantName: "Coffee Shop", type: .variable, entryMethod: .manual)
        context.insert(manual)
        try context.save()

        let linkedItemStore = StubLinkedItemStore(
            initial: LinkedItem(itemID: Self.defaultItemID, institutionName: "Bank One", linkedAt: .now)
        )
        linkedItemStore.save(LinkedItem(itemID: "item-2", institutionName: "Bank Two", linkedAt: .now))
        linkedItemStore.save(LinkedItem(itemID: "item-3", institutionName: "Bank Three", linkedAt: .now))

        ScriptedSyncURLProtocol.responses = [
            syncResponse(added: [transactionJSON(id: "plaid-item1-txn", amount: 12.50)], nextCursor: "cursor-item1"),
            syncResponse(added: [transactionJSON(id: "plaid-item2-txn", amount: 12.50)], nextCursor: "cursor-item2"),
            syncResponse(added: [transactionJSON(id: "plaid-item3-txn", amount: 12.50)], nextCursor: "cursor-item3"),
        ]
        let sut = makeSUT(linkedItemStore: linkedItemStore)

        await sut.runImport()

        XCTAssertEqual(sut.mergeQueue.count, 1, "the shared manual candidate must be matched at most once across every item processed this run, not once per item.")
        XCTAssertEqual(sut.mergeQueue.first?.incoming.plaidTransactionID, "plaid-item1-txn")
        XCTAssertEqual(
            Set(sut.mergeQueue.map(\.manualTransaction.persistentModelID)).count, sut.mergeQueue.count,
            "no manual transaction may appear behind more than one queued decision."
        )

        let fetched = try context.fetch(FetchDescriptor<SpendTransaction>())
        XCTAssertEqual(fetched.count, 3, "manual (pending) + item-2's independent save + item-3's independent save.")
        let item2Import = try XCTUnwrap(fetched.first { $0.plaidTransactionID == "plaid-item2-txn" })
        let item3Import = try XCTUnwrap(fetched.first { $0.plaidTransactionID == "plaid-item3-txn" })
        XCTAssertEqual(item2Import.plaidItemID, "item-2")
        XCTAssertEqual(item3Import.plaidItemID, "item-3")
    }

    // MARK: - modified

    func testRunImport_modified_overridePreserved() async throws {
        let existing = SpendTransaction(
            amount: 10, date: .now, merchantName: "Old Name", type: .fixed, entryMethod: .imported,
            plaidTransactionID: "plaid-1", isManualOverride: true
        )
        context.insert(existing)
        try context.save()

        ScriptedSyncURLProtocol.responses = [
            syncResponse(modified: [transactionJSON(id: "plaid-1", amount: 15, merchantName: "New Name")], nextCursor: "cursor-1")
        ]
        let sut = makeSUT()
        await sut.runImport()

        let fetched = try context.fetch(FetchDescriptor<SpendTransaction>())
        XCTAssertEqual(fetched.first?.amount, 15)
        XCTAssertEqual(fetched.first?.merchantName, "New Name")
        XCTAssertEqual(fetched.first?.type, .fixed, "isManualOverride == true must protect type from re-tagging.")
        XCTAssertEqual(sut.lastImportSummary?.modified, 1)
    }

    func testRunImport_modified_noOverride_retagged() async throws {
        context.insert(MerchantRule(merchantName: "New Name", type: .fixed))
        let existing = SpendTransaction(
            amount: 10, date: .now, merchantName: "Old Name", type: .variable, entryMethod: .imported,
            plaidTransactionID: "plaid-1", isManualOverride: false
        )
        context.insert(existing)
        try context.save()

        ScriptedSyncURLProtocol.responses = [
            syncResponse(modified: [transactionJSON(id: "plaid-1", amount: 15, merchantName: "New Name")], nextCursor: "cursor-1")
        ]
        let sut = makeSUT()
        await sut.runImport()

        let fetched = try context.fetch(FetchDescriptor<SpendTransaction>())
        XCTAssertEqual(fetched.first?.type, .fixed, "merchant-name change must trigger a fresh MerchantMatcher re-match.")
    }

    /// A `modified` event whose new amount is non-positive (review finding 4) -- e.g.
    /// reclassified as a refund -- must not be silently dropped by the `guard let mapped
    /// = ... else { continue }` before the existing row is ever looked up. A pure import
    /// is hard-deleted, matching how a genuine `removed` event is handled.
    func testRunImport_modified_nonPositiveAmount_pureImport_isHardDeleted() async throws {
        let existing = SpendTransaction(
            amount: 10, date: .now, merchantName: "Grocery", type: .variable, entryMethod: .imported,
            plaidTransactionID: "plaid-1", wasMergedFromManual: false
        )
        context.insert(existing)
        try context.save()

        ScriptedSyncURLProtocol.responses = [
            syncResponse(modified: [transactionJSON(id: "plaid-1", amount: -5.00)], nextCursor: "cursor-1")
        ]
        let sut = makeSUT()
        await sut.runImport()

        let fetched = try context.fetch(FetchDescriptor<SpendTransaction>())
        XCTAssertTrue(fetched.isEmpty, "A modified event reclassifying the transaction as non-positive must delete the stale pure import, not leave its pre-refund amount stale forever.")
    }

    /// Same as above, but for a merge-derived row (review finding 4) -- reverted to
    /// `.manual` rather than hard-deleted, matching a genuine `removed` event's handling,
    /// since deleting it would destroy data the user entered themselves.
    func testRunImport_modified_nonPositiveAmount_mergeDerived_isRevertedNotDeleted() async throws {
        let existing = SpendTransaction(
            amount: 10, date: .now, merchantName: "Grocery", type: .fixed, entryMethod: .imported,
            plaidTransactionID: "plaid-1", isManualOverride: true, wasMergedFromManual: true
        )
        context.insert(existing)
        try context.save()

        ScriptedSyncURLProtocol.responses = [
            syncResponse(modified: [transactionJSON(id: "plaid-1", amount: -5.00)], nextCursor: "cursor-1")
        ]
        let sut = makeSUT()
        await sut.runImport()

        let fetched = try context.fetch(FetchDescriptor<SpendTransaction>())
        XCTAssertEqual(fetched.count, 1, "A merge-derived row must survive a non-positive-amount modified event, reverted rather than deleted.")
        XCTAssertEqual(fetched.first?.entryMethod, .manual)
        XCTAssertNil(fetched.first?.plaidTransactionID)
        XCTAssertEqual(fetched.first?.wasMergedFromManual, false)
        XCTAssertEqual(fetched.first?.merchantName, "Grocery", "Every other field must be untouched by the revert.")
    }

    // MARK: - modified/removed for a still-queued merge decision (review finding 3)

    /// A queued-not-saved decision is a frozen snapshot never added to
    /// `importedByPlaidID`, so a later `modified` event for that same
    /// `transaction_id` (e.g. the incoming amount was corrected) must update the
    /// pending decision's stored snapshot rather than being silently ignored -- otherwise
    /// resolving "Merge" later would write stale data into the user's manual entry.
    func testRunImport_modifiedEventForStillQueuedItem_updatesPendingDecisionSnapshot() async throws {
        let manual = SpendTransaction(amount: 12.50, date: matchingFixtureDate, merchantName: "Coffee Shop", type: .variable, entryMethod: .manual)
        context.insert(manual)
        try context.save()

        ScriptedSyncURLProtocol.responses = [
            syncResponse(added: [transactionJSON(id: "plaid-1", amount: 12.50)], nextCursor: "cursor-1", hasMore: true),
            syncResponse(modified: [transactionJSON(id: "plaid-1", amount: 15.00, merchantName: "Coffee Shop Corrected")], nextCursor: "cursor-2"),
        ]
        let sut = makeSUT()
        await sut.runImport()

        XCTAssertEqual(sut.mergeQueue.count, 1, "still exactly one pending decision, refreshed rather than duplicated or dropped.")
        XCTAssertEqual(sut.pendingMergeDecision?.incoming.amount, 15.00, "the queued snapshot must reflect the modified event's corrected amount, not the stale original.")
        XCTAssertEqual(sut.pendingMergeDecision?.incoming.merchantName, "Coffee Shop Corrected")

        // Resolving "Merge" afterward must use the corrected data, not the original.
        sut.resolveMergeDecision(.merge)
        let fetched = try context.fetch(FetchDescriptor<SpendTransaction>())
        XCTAssertEqual(fetched.first?.amount, 15.00)
        XCTAssertEqual(fetched.first?.merchantName, "Coffee Shop Corrected")
    }

    /// A `removed` event for a still-queued decision (the incoming transaction was
    /// voided/reversed before the user resolved the merge prompt) must clear the pending
    /// decision entirely (UX call: the merge prompt simply disappears, treated as "no
    /// longer a live duplicate to resolve" -- see `TransactionImportService`'s doc
    /// comment) rather than leaving it pointing at data that no longer exists on Plaid's
    /// side. The manual transaction itself is left untouched.
    func testRunImport_removedEventForStillQueuedItem_clearsPendingDecision() async throws {
        let manual = SpendTransaction(amount: 12.50, date: matchingFixtureDate, merchantName: "Coffee Shop", type: .variable, entryMethod: .manual)
        context.insert(manual)
        try context.save()

        ScriptedSyncURLProtocol.responses = [
            syncResponse(added: [transactionJSON(id: "plaid-1", amount: 12.50)], nextCursor: "cursor-1", hasMore: true),
            syncResponse(removed: [removedJSON(id: "plaid-1")], nextCursor: "cursor-2"),
        ]
        let sut = makeSUT()
        await sut.runImport()

        XCTAssertTrue(sut.mergeQueue.isEmpty, "A removed event for a still-queued transaction must clear the pending decision, not leave it dangling.")
        let fetched = try context.fetch(FetchDescriptor<SpendTransaction>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.entryMethod, .manual, "The manual transaction itself must be untouched -- only the pending decision is cleared.")

        // The persisted PendingTransactionMerge row must also be gone, not just the
        // in-memory mergeQueue -- otherwise a fresh service instance would resurrect it.
        let relaunchedSUT = makeSUT()
        XCTAssertTrue(relaunchedSUT.mergeQueue.isEmpty)
    }

    // MARK: - removed

    func testRunImport_removed_pureImport_isHardDeleted() async throws {
        let existing = SpendTransaction(
            amount: 10, date: .now, merchantName: "Grocery", type: .variable, entryMethod: .imported,
            plaidTransactionID: "plaid-1", wasMergedFromManual: false
        )
        context.insert(existing)
        try context.save()

        ScriptedSyncURLProtocol.responses = [
            syncResponse(removed: [removedJSON(id: "plaid-1")], nextCursor: "cursor-1")
        ]
        let sut = makeSUT()
        await sut.runImport()

        let fetched = try context.fetch(FetchDescriptor<SpendTransaction>())
        XCTAssertTrue(fetched.isEmpty, "A pure import must be hard-deleted on removed.")
        XCTAssertEqual(sut.lastImportSummary?.removed, 1)
    }

    func testRunImport_removed_mergeDerived_isRevertedNotDeleted() async throws {
        let existing = SpendTransaction(
            amount: 10, date: .now, merchantName: "Grocery", type: .fixed, entryMethod: .imported,
            plaidTransactionID: "plaid-1", isManualOverride: true, wasMergedFromManual: true
        )
        context.insert(existing)
        try context.save()

        ScriptedSyncURLProtocol.responses = [
            syncResponse(removed: [removedJSON(id: "plaid-1")], nextCursor: "cursor-1")
        ]
        let sut = makeSUT()
        await sut.runImport()

        let fetched = try context.fetch(FetchDescriptor<SpendTransaction>())
        XCTAssertEqual(fetched.count, 1, "A merge-derived row must survive removal, reverted rather than deleted.")
        XCTAssertEqual(fetched.first?.entryMethod, .manual)
        XCTAssertNil(fetched.first?.plaidTransactionID)
        XCTAssertEqual(fetched.first?.wasMergedFromManual, false)
        XCTAssertEqual(fetched.first?.merchantName, "Grocery", "Every other field must be untouched by the revert.")
    }

    // MARK: - Save failure blocks cursor advance

    /// Opens a fresh on-disk store, seeds it with a normal (writable) container, then
    /// reopens the *same* file with `allowsSave: false` — same technique
    /// `PersistenceSaveHelperTests.makeReadOnlyContext()` uses. Any
    /// `modelContext.save()` against the resulting context genuinely throws,
    /// deterministically, giving real coverage of `TransactionImportService`'s
    /// per-transaction log-and-skip + cursor-blocking behavior without mocking
    /// `PersistenceSaveHelper` or `ModelContext` — a lighter-weight technique (an insert
    /// colliding with `SpendTransaction.plaidTransactionID`'s `@Attribute(.unique)`
    /// constraint) was tried first but turned out not to throw: SwiftData resolves that
    /// collision as an upsert rather than a `save()` failure.
    private func makeReadOnlyContext() throws -> (context: ModelContext, storeURL: URL) {
        let schema = Schema(versionedSchema: SchemaV9.self)
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TransactionImportServiceTests-\(UUID().uuidString)")
            .appendingPathExtension("store")
        addTeardownBlock {
            for suffix in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: storeURL.path + suffix))
            }
        }

        let seedConfiguration = ModelConfiguration(schema: schema, url: storeURL)
        let seedContainer = try ModelContainer(for: schema, migrationPlan: ReservoirMigrationPlan.self, configurations: [seedConfiguration])
        try ModelContext(seedContainer).save()

        let readOnlyConfiguration = ModelConfiguration(schema: schema, url: storeURL, allowsSave: false)
        let readOnlyContainer = try ModelContainer(for: schema, migrationPlan: ReservoirMigrationPlan.self, configurations: [readOnlyConfiguration])
        return (ModelContext(readOnlyContainer), storeURL)
    }

    /// Every write in this page fails (the store is read-only), which can't distinguish
    /// "one of several items failed" from "all of them failed" — but it does prove the
    /// two things that matter: (1) a genuine `saveOrRollback` failure blocks the page's
    /// cursor advance (unlike a queued-merge-only page, which still advances — see
    /// `testRunImport_pageWithOnlyQueuedMergeItem_stillAdvancesCursor` above), and (2) a
    /// second item's processing isn't aborted by the first item's failure (the loop
    /// completes normally rather than throwing/crashing) — the per-transaction isolation
    /// itself is exercised by every passing test above, all of which succeed
    /// independently in the same loop.
    func testRunImport_saveFailure_blocksCursorAdvance_doesNotAbortProcessingRemainingItems() async throws {
        let (readOnlyContext, storeURL) = try makeReadOnlyContext()

        ScriptedSyncURLProtocol.responses = [
            syncResponse(
                added: [
                    transactionJSON(id: "plaid-1", amount: 12.50, merchantName: "Coffee Shop"),
                    transactionJSON(id: "plaid-2", amount: 20, merchantName: "Grocery"),
                ],
                nextCursor: "cursor-1"
            )
        ]
        let cursorStore = StubCursorStore()
        let sut = TransactionImportService(
            modelContext: readOnlyContext,
            keychain: StubKeychainWithToken(),
            urlSession: makeScriptedURLSession(),
            environmentStore: StubEnvironmentStore(.sandbox),
            cursorStore: cursorStore,
            linkedItemStore: StubLinkedItemStore(
                initial: LinkedItem(itemID: Self.defaultItemID, institutionName: "Test Bank", linkedAt: .now)
            ),
            linkedAccountStore: StubLinkedAccountStore(),
            backfillStore: StubAccountBackfillStore(defaultComplete: true),
            syncLog: InMemorySyncLog(),
            lastSyncStore: InMemoryLastSync()
        )

        await sut.runImport()

        XCTAssertNil(cursorStore.cursor(for: .sandbox, itemID: Self.defaultItemID), "A page with a genuine save failure must not advance the cursor.")
        XCTAssertEqual(sut.lastImportSummary?.added, 0, "Neither failed write counts toward the summary.")

        // Verify against a *fresh* container reopened from the same store file, rather
        // than the same in-memory `readOnlyContext` — a rolled-back insert/delete pair
        // within one context's pending changes isn't a reliable signal to assert on
        // directly (SwiftData's in-memory change tracking around a read-only store has
        // sharp edges independent of what this test cares about), but what actually
        // landed on disk is the real question this test needs answered.
        let verificationSchema = Schema(versionedSchema: SchemaV9.self)
        let verificationContainer = try ModelContainer(
            for: verificationSchema,
            migrationPlan: ReservoirMigrationPlan.self,
            configurations: [ModelConfiguration(schema: verificationSchema, url: storeURL)]
        )
        let fetched = try ModelContext(verificationContainer).fetch(FetchDescriptor<SpendTransaction>())
        XCTAssertTrue(fetched.isEmpty, "Failed inserts must roll back, not persist half-applied.")
    }

    // MARK: - handleScenePhaseTransition (adq.6.4 foreground-refresh trigger)
    //
    // `handleScenePhaseTransition` takes only the new phase, one call per real
    // `.onChange(of: scenePhase)` firing — a real device delivers a return from
    // background as *two* separate calls (`.background`, then `.inactive`, then
    // `.active`... i.e. `to: .background`, `to: .inactive`, `to: .active` as three
    // distinct calls), never one call spanning both endpoints. These tests drive the
    // exact call sequence a real device would produce, not synthetic (old, new) pairs.

    /// The realistic backgrounding-then-foregrounding sequence: `.active -> .inactive ->
    /// .background -> .inactive -> .active`, delivered as five separate calls. Only the
    /// final call (landing on `.active` after a genuine `.background` sighting) should
    /// invoke `runImport()`.
    func testHandleScenePhaseTransition_realBackgroundForegroundSequence_firesRunImportOnce() async {
        ScriptedSyncURLProtocol.responses = [
            syncResponse(added: [transactionJSON(id: "plaid-1", amount: 12.50)], nextCursor: "cursor-1")
        ]
        let sut = makeSUT()

        await sut.handleScenePhaseTransition(to: .inactive)
        await sut.handleScenePhaseTransition(to: .background)
        XCTAssertEqual(ScriptedSyncURLProtocol.callCount, 0, "must not import while merely backgrounding, before returning to active.")

        await sut.handleScenePhaseTransition(to: .inactive)
        await sut.handleScenePhaseTransition(to: .active)

        XCTAssertEqual(ScriptedSyncURLProtocol.callCount, 1, "a genuine return from background must invoke the import pipeline exactly once.")
        XCTAssertEqual(sut.lastImportSummary?.added, 1)
    }

    /// Cold launch's scene-phase sequence is `.inactive -> .active` (SwiftUI never
    /// reports an initial `.background` phase), so it must NOT be mistaken for a return
    /// from backgrounding — Link itself just happened in that case per the bead's UX
    /// notes, and a separate first-launch-import story would own this if wanted.
    func testHandleScenePhaseTransition_coldLaunchSequence_doesNotFireRunImport() async {
        ScriptedSyncURLProtocol.responses = [
            syncResponse(added: [transactionJSON(id: "plaid-1", amount: 12.50)], nextCursor: "cursor-1")
        ]
        let sut = makeSUT()

        await sut.handleScenePhaseTransition(to: .inactive)
        await sut.handleScenePhaseTransition(to: .active)

        XCTAssertEqual(ScriptedSyncURLProtocol.callCount, 0, "cold-launch's inactive -> active sequence must not trigger an import.")
        XCTAssertNil(sut.lastImportSummary)
    }

    /// A brief `.inactive` blip that never actually reaches `.background` (e.g. pulling
    /// down Control Center while already active) must not be mistaken for a real return
    /// from backgrounding — only an observed `.background` phase should arm the next
    /// `.active` transition. Distinct from the cold-launch test above: this one starts
    /// from a genuinely active session, not from app launch.
    func testHandleScenePhaseTransition_inactiveBlipWithoutBackgrounding_doesNotFireRunImport() async {
        ScriptedSyncURLProtocol.responses = [
            syncResponse(added: [transactionJSON(id: "plaid-1", amount: 12.50)], nextCursor: "cursor-1")
        ]
        let sut = makeSUT()
        await sut.handleScenePhaseTransition(to: .inactive)
        await sut.handleScenePhaseTransition(to: .active)
        ScriptedSyncURLProtocol.responses = [
            syncResponse(added: [transactionJSON(id: "plaid-2", amount: 5.00)], nextCursor: "cursor-2")
        ]

        await sut.handleScenePhaseTransition(to: .inactive)
        await sut.handleScenePhaseTransition(to: .active)

        XCTAssertEqual(ScriptedSyncURLProtocol.callCount, 0, "an inactive blip that never reaches .background must not trigger an import.")
        XCTAssertNil(sut.lastImportSummary)
    }

    /// Backgrounding alone (never returning to `.active`) must not fire an import — only
    /// the subsequent transition *into* `.active` should.
    func testHandleScenePhaseTransition_backgroundingAlone_doesNotFireRunImport() async {
        ScriptedSyncURLProtocol.responses = [
            syncResponse(added: [transactionJSON(id: "plaid-1", amount: 12.50)], nextCursor: "cursor-1")
        ]
        let sut = makeSUT()

        await sut.handleScenePhaseTransition(to: .inactive)
        await sut.handleScenePhaseTransition(to: .background)

        XCTAssertEqual(ScriptedSyncURLProtocol.callCount, 0, "backgrounding alone (never returning to active) must not trigger an import.")
        XCTAssertNil(sut.lastImportSummary)
    }

    /// Code-review finding: the original fix reset `hasBackgroundedSinceActive` before
    /// calling `runImport()`, so a foreground trigger landing while another import was
    /// already in flight silently lost that sync for the whole cycle (`runImport()`'s own
    /// `guard !isImporting` made the call a no-op, but the flag was already spent). This
    /// drives that exact scenario with `SlowSyncURLProtocol` gating an in-flight import,
    /// and confirms the flag survives to retry on the very next `.active` transition.
    func testHandleScenePhaseTransition_activeWhileAnotherImportInFlight_doesNotConsumeFlag_retriesOnNextActive() async {
        SlowSyncURLProtocol.response = syncResponse(added: [transactionJSON(id: "plaid-1", amount: 12.50)], nextCursor: "cursor-1")
        let sut = TransactionImportService(
            modelContext: context,
            keychain: StubKeychainWithToken(),
            urlSession: makeSlowURLSession(),
            environmentStore: StubEnvironmentStore(.sandbox),
            cursorStore: StubCursorStore(),
            linkedItemStore: StubLinkedItemStore(
                initial: LinkedItem(itemID: Self.defaultItemID, institutionName: "Test Bank", linkedAt: .now)
            ),
            linkedAccountStore: StubLinkedAccountStore(),
            backfillStore: StubAccountBackfillStore(defaultComplete: true),
            syncLog: InMemorySyncLog(),
            lastSyncStore: InMemoryLastSync()
        )

        // Simulate an already-in-flight import (e.g. pull-to-refresh) blocked on the network.
        let inFlight = Task { await sut.runImport() }
        var waited = 0
        while !sut.isImporting, waited < 50 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            waited += 1
        }
        XCTAssertTrue(sut.isImporting, "setup precondition: the in-flight import must actually be running before proceeding.")

        // A foreground return lands while that import is still in flight.
        await sut.handleScenePhaseTransition(to: .background)
        await sut.handleScenePhaseTransition(to: .active)
        XCTAssertEqual(SlowSyncURLProtocol.callCount, 0, "must not have completed a second import yet -- the in-flight one is still gated.")

        // Let the in-flight import finish. The upcoming retry makes its own real network
        // call through the same slow protocol, so pre-arm a second signal for it now --
        // otherwise that call blocks on an already-exhausted semaphore (this test's own
        // original bug, see `SlowSyncURLProtocol.startLoading()`'s comment).
        SlowSyncURLProtocol.gate.signal()
        SlowSyncURLProtocol.gate.signal()
        await inFlight.value
        XCTAssertEqual(SlowSyncURLProtocol.callCount, 1)

        // The flag must have survived (not been consumed) the earlier no-op attempt --
        // the very next `.active` transition, with no additional `.background` in between,
        // must now retry and succeed.
        await sut.handleScenePhaseTransition(to: .active)
        XCTAssertEqual(SlowSyncURLProtocol.callCount, 2, "the foreground trigger that landed mid-import must retry once the prior import finishes, not be silently dropped for this cycle.")
    }

    // MARK: - presentedErrorDetail (code-review finding: pull-to-refresh failures were silent)

    /// A malformed `/transactions/sync` response fails JSON decoding inside `syncPage`,
    /// landing in `runImport()`'s `catch` — verifies `presentedErrorDetail` is populated
    /// with the raw underlying error alongside the coarse `presentedError` category, so a
    /// UI can offer an opt-in "technical details" reveal without changing the default,
    /// friendly copy `presentedError.userFacingMessage` still drives.
    func testRunImport_syncFailure_populatesPresentedErrorDetailAlongsideCategory() async {
        ScriptedSyncURLProtocol.responses = [Data("not valid json".utf8)]
        let sut = makeSUT()

        await sut.runImport()

        XCTAssertEqual(sut.presentedError, .plaidSide)
        XCTAssertNotNil(sut.presentedErrorDetail, "the raw underlying error must be retained, not discarded, at classification time.")
        XCTAssertFalse(sut.presentedErrorDetail?.isEmpty ?? true)
    }

    /// A successful run must clear any previously-set detail, not just the category —
    /// otherwise a stale technical detail could linger and be shown for an error that no
    /// longer applies.
    func testRunImport_successAfterFailure_clearsPresentedErrorDetail() async {
        ScriptedSyncURLProtocol.responses = [Data("not valid json".utf8)]
        let sut = makeSUT()
        await sut.runImport()
        XCTAssertNotNil(sut.presentedErrorDetail)

        ScriptedSyncURLProtocol.reset()
        ScriptedSyncURLProtocol.responses = [
            syncResponse(added: [transactionJSON(id: "plaid-1", amount: 12.50)], nextCursor: "cursor-1")
        ]

        await sut.runImport()

        XCTAssertNil(sut.presentedError)
        XCTAssertNil(sut.presentedErrorDetail)
    }

    // MARK: - needsAttention (reservoir-adq.6.5 — ITEM_LOGIN_REQUIRED classification)

    /// A genuine `ITEM_LOGIN_REQUIRED` error body decoded from a non-2xx `/transactions/
    /// sync` response must set `needsAttention` (both the in-memory published property
    /// and the persisted `linkedItemStore`), and classify `presentedError` distinctly from
    /// every other failure category — this is the acceptance criterion's core assertion,
    /// and only reachable now that `post(_:body:baseURL:)` decodes the failure body
    /// instead of discarding it.
    func testRunImport_itemLoginRequiredError_setsNeedsAttentionAndClassifiesDistinctly() async {
        ScriptedSyncURLProtocol.responses = [itemErrorResponse(errorCode: "ITEM_LOGIN_REQUIRED")]
        ScriptedSyncURLProtocol.statusCodes = [400]
        let linkedItemStore = StubLinkedItemStore(initial: LinkedItem(itemID: "item-1", institutionName: "Test Bank", linkedAt: .now))
        let sut = makeSUT(linkedItemStore: linkedItemStore)

        await sut.runImport()

        XCTAssertEqual(sut.presentedError, .itemLoginRequired)
        XCTAssertTrue(sut.needsAttention, "the in-memory flag must be set so the Today-screen badge (bound to it) reacts immediately.")
        XCTAssertEqual(linkedItemStore.setNeedsAttentionCalls, [true], "the persisted flag must also be set, so it survives past this TransactionImportService instance.")
        XCTAssertEqual(linkedItemStore.loadAll().first?.needsAttention, true)
    }

    /// A different (non-`ITEM_LOGIN_REQUIRED`) item-level error still falls back to
    /// `.plaidSide` (see `PlaidErrorClassifierTests`) and must NOT set `needsAttention` —
    /// only the well-defined case this story resolves gets the persistent-UI treatment.
    func testRunImport_otherItemError_doesNotSetNeedsAttention() async {
        ScriptedSyncURLProtocol.responses = [itemErrorResponse(errorCode: "ITEM_NOT_SUPPORTED")]
        ScriptedSyncURLProtocol.statusCodes = [400]
        let linkedItemStore = StubLinkedItemStore(initial: LinkedItem(itemID: "item-1", institutionName: "Test Bank", linkedAt: .now))
        let sut = makeSUT(linkedItemStore: linkedItemStore)

        await sut.runImport()

        XCTAssertEqual(sut.presentedError, .plaidSide)
        XCTAssertFalse(sut.needsAttention)
        XCTAssertTrue(linkedItemStore.setNeedsAttentionCalls.isEmpty)
    }

    /// A malformed (non-Plaid-error-shaped) non-2xx body — e.g. an HTML error page, an
    /// empty body — falls back to the pre-existing `URLError(.badServerResponse)` ->
    /// `.plaidSide` path (see `post(_:body:baseURL:)`'s doc comment on preserved
    /// behavior) and must not set `needsAttention` either.
    func testRunImport_malformedNon2xxBody_classifiesAsPlaidSide_doesNotSetNeedsAttention() async {
        ScriptedSyncURLProtocol.responses = [Data("<html>not json</html>".utf8)]
        ScriptedSyncURLProtocol.statusCodes = [500]
        let linkedItemStore = StubLinkedItemStore(initial: LinkedItem(itemID: "item-1", institutionName: "Test Bank", linkedAt: .now))
        let sut = makeSUT(linkedItemStore: linkedItemStore)

        await sut.runImport()

        XCTAssertEqual(sut.presentedError, .plaidSide)
        XCTAssertFalse(sut.needsAttention)
        XCTAssertTrue(linkedItemStore.setNeedsAttentionCalls.isEmpty)
    }

    /// A genuine transport/network failure (no HTTP response at all) must not set
    /// needsAttention — the acceptance criterion's explicit "a flaky connection during a
    /// foreground refresh must not falsely trigger the persistent UI" case.
    func testRunImport_genuineNetworkError_doesNotSetNeedsAttention() async {
        let linkedItemStore = StubLinkedItemStore(initial: LinkedItem(itemID: "item-1", institutionName: "Test Bank", linkedAt: .now))
        let sut = makeSUT(linkedItemStore: linkedItemStore, urlSession: makeNetworkFailureURLSession())

        await sut.runImport()

        XCTAssertEqual(sut.presentedError, .network)
        XCTAssertFalse(sut.needsAttention)
        XCTAssertTrue(linkedItemStore.setNeedsAttentionCalls.isEmpty)
    }

    /// `needsAttention` must be readable immediately at construction (not only after a
    /// `runImport()` call) — the Today-screen badge binds to a `TransactionImportService`
    /// instance that may render before any import has run this session, e.g. right after
    /// app launch with a flag already set from a prior session.
    func testInit_syncsNeedsAttentionFromPersistedStore() {
        let linkedItemStore = StubLinkedItemStore(initial: LinkedItem(itemID: "item-1", institutionName: "Test Bank", linkedAt: .now, needsAttention: true))
        let sut = makeSUT(linkedItemStore: linkedItemStore)

        XCTAssertTrue(sut.needsAttention)
    }

    /// `refreshNeedsAttention()` re-reads the persisted flag on demand — used by
    /// `PlaidDebugLinkView` right after a successful relink so the badge clears
    /// immediately rather than waiting for the next `runImport()` call.
    func testRefreshNeedsAttention_reReadsFromStore() {
        let linkedItemStore = StubLinkedItemStore(initial: LinkedItem(itemID: "item-1", institutionName: "Test Bank", linkedAt: .now, needsAttention: true))
        let sut = makeSUT(linkedItemStore: linkedItemStore)
        XCTAssertTrue(sut.needsAttention, "sanity check: seeded true at init.")

        linkedItemStore.setNeedsAttention(false, itemID: "item-1")
        sut.refreshNeedsAttention()

        XCTAssertFalse(sut.needsAttention)
    }

    /// Regression coverage for reservoir-loc.2: with more than one linked item,
    /// `needsAttention` must be an OR across every item, not a `.first`-only read — a
    /// non-first item's login-required state must not be masked by an earlier, still-healthy
    /// item. Guards against reverting to the pre-loc.2 single-pointer read that would have
    /// silently reported `false` here despite item-2 genuinely needing attention.
    func testNeedsAttention_multipleItems_isOrAcrossAllItems_notFirstItemOnly() {
        let linkedItemStore = StubLinkedItemStore(
            initial: LinkedItem(itemID: "item-1", institutionName: "Bank One", linkedAt: .now, needsAttention: false)
        )
        linkedItemStore.save(LinkedItem(itemID: "item-2", institutionName: "Bank Two", linkedAt: .now, needsAttention: true))
        let sut = makeSUT(linkedItemStore: linkedItemStore)

        XCTAssertTrue(sut.needsAttention, "item-2 (not the first item) needing attention must not be masked by item-1's healthy state.")

        linkedItemStore.setNeedsAttention(false, itemID: "item-2")
        sut.refreshNeedsAttention()

        XCTAssertFalse(sut.needsAttention, "once every item is healthy again, the OR must clear too.")
    }

    /// Code-review finding (reservoir-adq.6.5): `runImport()`'s no-access-token guard used
    /// to `return` before `refreshNeedsAttention()` ran. A Plaid environment switch clears
    /// both the Keychain token and the persisted linked item (`PlaidEnvironmentStore
    /// .onChange`), but without resyncing here, `needsAttention` would stay stuck at its
    /// last in-memory value from *before* the switch — e.g. `true` from a flagged item that
    /// no longer exists — permanently showing the Today-screen badge with nothing to
    /// reconnect. `runImport()` must resync `needsAttention` on this early-return path too,
    /// not just on the paths that reach a real sync attempt.
    func testRunImport_noAccessToken_stillResyncsNeedsAttentionFromStore() async {
        let linkedItemStore = StubLinkedItemStore(initial: nil) // env switch already cleared it.
        let sut = makeSUT(keychain: StubKeychain(), linkedItemStore: linkedItemStore)
        // Simulate the stale in-memory flag a prior session (before the environment
        // switch) would have left behind — `needsAttention` is `private(set)`, so drive it
        // the same way the app would: seed a flagged item, sync it in, then clear the
        // store out from under the instance (exactly what `PlaidEnvironmentStore.onChange`
        // does to `LinkedItemStore` without this instance's knowledge).
        linkedItemStore.save(LinkedItem(itemID: "item-1", institutionName: "Test Bank", linkedAt: .now, needsAttention: true))
        sut.refreshNeedsAttention()
        XCTAssertTrue(sut.needsAttention, "sanity check: starts stale-true, matching a flagged item from before the switch.")
        linkedItemStore.remove(itemID: "item-1")

        await sut.runImport()

        XCTAssertFalse(
            sut.needsAttention,
            "the no-access-token early return must still resync from the store, which now reports nothing linked."
        )
    }

    /// Reproduces `PlaidDebugLinkView`'s Relink flow — a real `PlaidServiceLive` sharing
    /// the same `LinkedItemStoring` backing as this `TransactionImportService`, the way the
    /// two are actually wired via DI in the app — and asserts the fixed (reservoir-1nn)
    /// behavior: `TransactionImportService.needsAttention` (what the Today-screen badge is
    /// bound to) only clears once relink has *genuinely* completed, and does so promptly
    /// at that point with no further trigger needed.
    ///
    /// `startRelink(for:)` only *awaits* through token creation and setting
    /// `isPresentingLink = true` — it returns as soon as the update-mode Link sheet is
    /// handed to SwiftUI, well before the user has done anything in it.
    /// `handleRelinkSuccess()` — which actually clears `needsAttention` — only runs later,
    /// from LinkKit's `onSuccess` closure, once the user completes the sheet. The fix wires
    /// `PlaidServiceLive.onRelinkSuccess` (fired from inside `handleRelinkSuccess()`, after
    /// the flag is cleared) to `TransactionImportService.refreshNeedsAttention()` —
    /// `PlaidDebugLinkView` sets this closure, but the mechanism itself lives on
    /// `PlaidServiceLive` and is exercised directly here, with no view in the loop.
    func testRelinkSuccess_refreshesNeedsAttentionOnceRelinkActuallyCompletes() async {
        let linkedItemStore = StubLinkedItemStore(
            initial: LinkedItem(itemID: "item-1", institutionName: "Test Bank", linkedAt: .now, needsAttention: true)
        )
        let plaidService = PlaidServiceLive(
            keychain: StubKeychainWithAccessToken(),
            urlSession: makeLinkTokenURLSession(),
            linkedItemStore: linkedItemStore
        )
        let sut = makeSUT(linkedItemStore: linkedItemStore)
        XCTAssertTrue(sut.needsAttention, "sanity check: both services start in sync, seeded from the shared store.")
        let item = try! XCTUnwrap(plaidService.linkedItem)

        // Exactly what PlaidDebugLinkView wires on appear (reservoir-1nn's fix).
        plaidService.onRelinkSuccess = { sut.refreshNeedsAttention() }

        // Exactly PlaidDebugLinkView's Relink-button Task body.
        await plaidService.startRelink(for: item)

        XCTAssertTrue(
            sut.needsAttention,
            "startRelink's own await only covers token creation + presenting the Link " +
            "sheet — the user hasn't done anything in it yet, so the badge must not have " +
            "cleared."
        )

        // Now the user actually finishes the update-mode Link sheet (LinkKit's onSuccess
        // closure firing, asynchronously, well after startRelink's own await returned).
        plaidService.handleRelinkSuccess()

        XCTAssertFalse(
            sut.needsAttention,
            "handleRelinkSuccess() fires onRelinkSuccess after clearing the flag, which " +
            "refreshes TransactionImportService.needsAttention immediately — no further " +
            "runImport() or app relaunch required."
        )
    }

    // MARK: - Multi-page pagination

    func testRunImport_multiplePages_advancesCursorThroughToFinalPage() async throws {
        ScriptedSyncURLProtocol.responses = [
            syncResponse(added: [transactionJSON(id: "plaid-1", amount: 10, merchantName: "Merchant One")], nextCursor: "cursor-page1", hasMore: true),
            syncResponse(added: [transactionJSON(id: "plaid-2", amount: 20, merchantName: "Merchant Two")], nextCursor: "cursor-page2", hasMore: false),
        ]
        let cursorStore = StubCursorStore()
        let sut = makeSUT(cursorStore: cursorStore)

        await sut.runImport()

        XCTAssertEqual(ScriptedSyncURLProtocol.callCount, 2)
        XCTAssertEqual(cursorStore.cursor(for: .sandbox, itemID: Self.defaultItemID), "cursor-page2")
        let fetched = try context.fetch(FetchDescriptor<SpendTransaction>())
        XCTAssertEqual(fetched.count, 2)
        XCTAssertEqual(sut.lastImportSummary?.added, 2)
    }

    // MARK: - Post-link import (reservoir-xle)

    private func notReady(cursor: String = "") -> Data {
        syncResponse(nextCursor: cursor, status: "NOT_READY")
    }

    private func ready(id: String = "plaid-1", cursor: String = "cursor-ready", status: String = "INITIAL_UPDATE_COMPLETE", hasMore: Bool = false) -> Data {
        syncResponse(added: [transactionJSON(id: id, amount: 12.50)], nextCursor: cursor, hasMore: hasMore, status: status)
    }

    /// Records every requested wait without actually waiting.
    @MainActor private final class SleepRecorder {
        var durations: [Duration] = []
        var onSleep: ((Int) async -> Void)?
        func sleep(_ duration: Duration) async throws {
            durations.append(duration)
            await onSleep?(durations.count)
        }
    }

    func testWireType_decodesWithKnownUnknownAndMissingStatus() throws {
        func decode(_ extra: String, cursor: String = #""next_cursor": "c","#) throws -> PlaidSyncResponseBody {
            let json = #"{"added": [], "modified": [], "removed": [], \#(cursor) "has_more": false\#(extra)}"#
            return try JSONDecoder().decode(PlaidSyncResponseBody.self, from: Data(json.utf8))
        }
        XCTAssertEqual(try decode(#", "transactions_update_status": "NOT_READY""#).transactions_update_status, "NOT_READY")
        XCTAssertEqual(try decode(#", "transactions_update_status": "SOMETHING_NEW""#).transactions_update_status, "SOMETHING_NEW")
        XCTAssertNil(try decode("").transactions_update_status)
        XCTAssertNil(try decode("", cursor: "").next_cursor, "a missing next_cursor must decode, not throw.")
    }

    func testReadiness_shouldRetryOnlyForEmptyNotReady() throws {
        func response(_ status: String?, added: Bool = false, hasMore: Bool = false) throws -> PlaidSyncResponseBody {
            let tx = added ? transactionJSON(id: "t", amount: 1) : ""
            let statusField = status.map { #", "transactions_update_status": "\#($0)""# } ?? ""
            let json = #"{"added": [\#(tx)], "modified": [], "removed": [], "next_cursor": "c", "has_more": \#(hasMore)\#(statusField)}"#
            return try JSONDecoder().decode(PlaidSyncResponseBody.self, from: Data(json.utf8))
        }
        XCTAssertTrue(PlaidSyncReadiness.shouldRetry(try response("NOT_READY")))
        XCTAssertFalse(PlaidSyncReadiness.shouldRetry(try response("NOT_READY", added: true)))
        XCTAssertFalse(PlaidSyncReadiness.shouldRetry(try response("INITIAL_UPDATE_COMPLETE")))
        XCTAssertFalse(PlaidSyncReadiness.shouldRetry(try response("HISTORICAL_UPDATE_COMPLETE")))
        XCTAssertFalse(PlaidSyncReadiness.shouldRetry(try response("TRANSACTIONS_UPDATE_STATUS_UNKNOWN")))
        XCTAssertFalse(PlaidSyncReadiness.shouldRetry(try response(nil)), "an absent or unrecognized status must never loop.")
        XCTAssertNil(PlaidSyncReadiness.cursorToPersist(from: try response("NOT_READY")), "an empty not-ready page must not persist a cursor.")
        XCTAssertEqual(PlaidSyncReadiness.cursorToPersist(from: try response("INITIAL_UPDATE_COMPLETE")), "c")
    }

    func testRunImportAfterLink_retriesOnEmptyNotReady_thenImports() async throws {
        ScriptedSyncURLProtocol.responses = [notReady(), notReady(), ready()]
        let recorder = SleepRecorder()
        let cursorStore = StubCursorStore()
        let sut = makeSUT(cursorStore: cursorStore, sleep: recorder.sleep)

        await sut.runImportAfterLink(itemID: Self.defaultItemID)

        XCTAssertEqual(ScriptedSyncURLProtocol.callCount, 3)
        XCTAssertEqual(recorder.durations, [.seconds(1), .seconds(2)])
        XCTAssertEqual(try context.fetch(FetchDescriptor<SpendTransaction>()).count, 1)
        XCTAssertEqual(cursorStore.cursor(for: .sandbox, itemID: Self.defaultItemID), "cursor-ready")
        XCTAssertNil(sut.presentedError)
        XCTAssertFalse(sut.isInitialDataPending)
        XCTAssertFalse(sut.isImporting)
        XCTAssertFalse(sut.isInitialImport)
    }

    func testRunImportAfterLink_stopsAtBound_withoutError_andMarksPending() async throws {
        ScriptedSyncURLProtocol.responses = [notReady(cursor: "cursor-empty")]
        let recorder = SleepRecorder()
        let cursorStore = StubCursorStore()
        let sut = makeSUT(cursorStore: cursorStore, sleep: recorder.sleep)

        await sut.runImportAfterLink(itemID: Self.defaultItemID)

        XCTAssertEqual(ScriptedSyncURLProtocol.callCount, 4, "initial call plus one retry per backoff entry.")
        XCTAssertEqual(recorder.durations.count, 3)
        XCTAssertNil(sut.presentedError, "giving up is not an error.")
        XCTAssertTrue(sut.isInitialDataPending)
        XCTAssertFalse(sut.isImporting)
        XCTAssertNil(cursorStore.cursor(for: .sandbox, itemID: Self.defaultItemID), "a not-ready empty page must never advance the cursor.")
    }

    func testRunImportAfterLink_stopsImmediatelyOnInitialUpdateCompleteWithRows() async throws {
        ScriptedSyncURLProtocol.responses = [ready(status: "INITIAL_UPDATE_COMPLETE")]
        let recorder = SleepRecorder()
        let sut = makeSUT(sleep: recorder.sleep)

        await sut.runImportAfterLink(itemID: Self.defaultItemID)

        XCTAssertEqual(ScriptedSyncURLProtocol.callCount, 1)
        XCTAssertTrue(recorder.durations.isEmpty)
        XCTAssertEqual(sut.lastImportSummary?.added, 1)
    }

    func testRunImportAfterLink_historicalUpdateComplete_stopsAndPagingStillWorks() async throws {
        ScriptedSyncURLProtocol.responses = [
            notReady(),
            ready(id: "plaid-1", cursor: "cursor-p1", status: "INITIAL_UPDATE_COMPLETE", hasMore: true),
            ready(id: "plaid-2", cursor: "cursor-p2", status: "HISTORICAL_UPDATE_COMPLETE"),
        ]
        let recorder = SleepRecorder()
        let cursorStore = StubCursorStore()
        let sut = makeSUT(cursorStore: cursorStore, sleep: recorder.sleep)

        await sut.runImportAfterLink(itemID: Self.defaultItemID)

        XCTAssertEqual(ScriptedSyncURLProtocol.callCount, 3)
        XCTAssertEqual(recorder.durations.count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<SpendTransaction>()).count, 2)
        XCTAssertEqual(cursorStore.cursor(for: .sandbox, itemID: Self.defaultItemID), "cursor-p2")
    }

    func testRunImport_neverPersistsEmptyCursor_evenWithData() async throws {
        ScriptedSyncURLProtocol.responses = [ready(cursor: "")]
        let cursorStore = StubCursorStore()
        cursorStore.setCursor("old-cursor", for: .sandbox, itemID: Self.defaultItemID)
        let sut = makeSUT(cursorStore: cursorStore)

        await sut.runImport()

        XCTAssertEqual(cursorStore.cursor(for: .sandbox, itemID: Self.defaultItemID), "old-cursor")
        XCTAssertEqual(sut.lastImportSummary?.added, 1)
    }

    func testRunImport_plainRefresh_doesNotPoll_butFlagsPendingWhenNotReady() async {
        ScriptedSyncURLProtocol.responses = [notReady()]
        let recorder = SleepRecorder()
        let sut = makeSUT(sleep: recorder.sleep)

        await sut.runImport()

        XCTAssertEqual(ScriptedSyncURLProtocol.callCount, 1)
        XCTAssertTrue(recorder.durations.isEmpty)
        XCTAssertTrue(sut.isInitialDataPending)
        XCTAssertFalse(sut.isInitialImport)
        ScriptedSyncURLProtocol.responses = [ready()]
        await sut.runImport()
        XCTAssertFalse(sut.isInitialDataPending, "a later ready sync clears the pending flag.")
    }

    private func makeTwoItemStore() -> StubLinkedItemStore {
        let store = StubLinkedItemStore(initial: LinkedItem(itemID: "item-1", institutionName: "Polled", linkedAt: .now))
        store.save(LinkedItem(itemID: "item-2", institutionName: "Other", linkedAt: .now))
        return store
    }

    func testRunImportAfterLink_doesNotBlockForegroundSyncOfOtherItems() async throws {
        // Poll call 1 (item-1) not ready; the foreground sync during the wait syncs item-2
        // only; poll call 3 (item-1) is ready.
        ScriptedSyncURLProtocol.responses = [notReady(), ready(id: "p2", cursor: "c2"), ready(id: "p1", cursor: "c1")]
        let recorder = SleepRecorder()
        let cursorStore = StubCursorStore()
        let sut = makeSUT(cursorStore: cursorStore, linkedItemStore: makeTwoItemStore(), sleep: recorder.sleep)
        var isImportingDuringWait: Bool?
        var isInitialImportDuringWait: Bool?
        var callsAfterForeground = 0
        recorder.onSleep = { _ in
            isImportingDuringWait = sut.isImporting
            isInitialImportDuringWait = sut.isInitialImport
            await sut.handleScenePhaseTransition(to: .active)
            callsAfterForeground = ScriptedSyncURLProtocol.callCount
        }
        await sut.handleScenePhaseTransition(to: .background)

        await sut.runImportAfterLink(itemID: "item-1")

        XCTAssertEqual(isImportingDuringWait, false, "the poll must not mark an ordinary sync as running.")
        XCTAssertEqual(isInitialImportDuringWait, true)
        XCTAssertEqual(callsAfterForeground, 2, "the foreground sync ran, and synced only item-2 (one call), skipping the polled item.")
        XCTAssertEqual(cursorStore.cursor(for: .sandbox, itemID: "item-2"), "c2")
        XCTAssertEqual(cursorStore.cursor(for: .sandbox, itemID: "item-1"), "c1")
        XCTAssertEqual(try context.fetch(FetchDescriptor<SpendTransaction>()).count, 2)
        XCTAssertFalse(sut.isImporting)
        XCTAssertFalse(sut.isInitialImport)
    }

    func testRunImport_duringPoll_doesNotClobberPendingFlagOrDrainQueue() async {
        // Item-1 polls (never ready). During its wait: item-2's post-link is requested
        // (queued, one poll at a time) and an ordinary refresh runs.
        ScriptedSyncURLProtocol.responses = [notReady()]
        let recorder = SleepRecorder()
        let sut = makeSUT(linkedItemStore: makeTwoItemStore(), postLinkBackoff: [.seconds(1)], sleep: recorder.sleep)
        var pendingDuringWait: Bool?
        recorder.onSleep = { count in
            guard count == 1 else { return }
            await sut.runImportAfterLink(itemID: "item-2")
            let callsBefore = ScriptedSyncURLProtocol.callCount
            await sut.runImport()
            XCTAssertEqual(ScriptedSyncURLProtocol.callCount, callsBefore + 1, "refresh syncs item-2 once, without polling or draining the queue inline.")
            XCTAssertEqual(recorder.durations.count, 1, "no extra waits were started by the ordinary run.")
            pendingDuringWait = sut.isInitialDataPending
        }

        await sut.runImportAfterLink(itemID: "item-1")

        XCTAssertEqual(pendingDuringWait, false, "an ordinary run must not write the pending flag while the poll owns it.")
        // Poll 1: 2 calls (initial + 1 retry). Ordinary: 1. Queued item-2 poll: 2 calls.
        XCTAssertEqual(ScriptedSyncURLProtocol.callCount, 5)
        XCTAssertFalse(sut.isInitialImport)
    }

    func testRunImport_pollingItemIsExcluded_onlyItemsNotOwnedByPollSync() async {
        ScriptedSyncURLProtocol.responses = [notReady(), ready(id: "p2", cursor: "c2"), ready(id: "p1", cursor: "c1")]
        let cursorStore = StubCursorStore()
        let recorder = SleepRecorder()
        let sut = makeSUT(cursorStore: cursorStore, linkedItemStore: makeTwoItemStore(), sleep: recorder.sleep)
        recorder.onSleep = { _ in
            // Two overlapping ordinary requests: the second no-ops (single ordinary run).
            async let first: Void = sut.runImport()
            async let second: Void = sut.runImport()
            _ = await (first, second)
        }

        await sut.runImportAfterLink(itemID: "item-1")

        XCTAssertEqual(ScriptedSyncURLProtocol.callCount, 3, "poll(2) + exactly one ordinary sync of item-2(1).")
    }

    func testRunImportAfterLink_requestedWhileOrdinaryRunSyncsSameItem_isQueuedAndPolledAfterWithoutBlockingRefresh() async {
        ScriptedSyncURLProtocol.responses = [ready(), notReady()]
        let recorder = SleepRecorder()
        let sut = makeSUT(sleep: recorder.sleep)
        let ordinary = Task { await sut.runImport() }
        await Task.yield()
        await sut.runImportAfterLink(itemID: Self.defaultItemID)
        XCTAssertNil(sut.initialImportItemID, "queued, not started alongside the in-flight sync of the same item.")
        await ordinary.value

        XCTAssertFalse(sut.isImporting, "the ordinary run returned without waiting on the queued poll.")
        await sut.waitForQueuedPostLinkImports()

        XCTAssertEqual(recorder.durations.count, 3, "the queued item is polled by the detached drain, not inline.")
        XCTAssertEqual(ScriptedSyncURLProtocol.callCount, 1 + 4)
    }

    func testRunImportAfterLink_requestedWhileAnotherPollRuns_isQueuedAndRunsAfter() async {
        ScriptedSyncURLProtocol.responses = [ready()]
        let sut = makeSUT(linkedItemStore: makeTwoItemStore())
        let first = Task { await sut.runImportAfterLink(itemID: "item-1") }
        await Task.yield()
        await sut.runImportAfterLink(itemID: "item-2")
        await first.value

        XCTAssertNil(sut.initialImportItemID)
        XCTAssertEqual(ScriptedSyncURLProtocol.callCount, 2, "the queued post-link import runs after the in-flight poll finishes.")
    }

    func testRunImportAfterLink_itemLoginRequiredMidLoop_setsNeedsAttentionAndStops() async {
        ScriptedSyncURLProtocol.responses = [notReady(), itemErrorResponse(errorCode: "ITEM_LOGIN_REQUIRED"), ready()]
        ScriptedSyncURLProtocol.statusCodes = [200, 400, 200]
        let linkedItemStore = StubLinkedItemStore(initial: LinkedItem(itemID: Self.defaultItemID, institutionName: "Test Bank", linkedAt: .now))
        let sut = makeSUT(linkedItemStore: linkedItemStore)

        await sut.runImportAfterLink(itemID: Self.defaultItemID)

        XCTAssertEqual(ScriptedSyncURLProtocol.callCount, 2)
        XCTAssertEqual(sut.presentedError, .itemLoginRequired)
        XCTAssertTrue(sut.needsAttention)
        XCTAssertEqual(linkedItemStore.setNeedsAttentionCalls, [true])
        XCTAssertFalse(sut.isImporting)
    }

    func testRunImportAfterLink_serverFailureMidLoop_surfacesErrorWithoutNeedsAttention() async {
        ScriptedSyncURLProtocol.responses = [notReady(), Data()]
        ScriptedSyncURLProtocol.statusCodes = [200, 500]
        let linkedItemStore = StubLinkedItemStore(initial: LinkedItem(itemID: Self.defaultItemID, institutionName: "Test Bank", linkedAt: .now))
        let sut = makeSUT(linkedItemStore: linkedItemStore)

        await sut.runImportAfterLink(itemID: Self.defaultItemID)

        XCTAssertEqual(ScriptedSyncURLProtocol.callCount, 2)
        XCTAssertNotNil(sut.presentedError)
        XCTAssertFalse(sut.needsAttention)
        XCTAssertTrue(linkedItemStore.setNeedsAttentionCalls.isEmpty)
        XCTAssertFalse(sut.isImporting)
    }

    func testRunImportAfterLink_networkErrorOnFirstCall_surfacesError() async {
        let sut = makeSUT(urlSession: makeNetworkFailureURLSession())

        await sut.runImportAfterLink(itemID: Self.defaultItemID)

        XCTAssertNotNil(sut.presentedError)
        XCTAssertFalse(sut.needsAttention)
        XCTAssertFalse(sut.isImporting)
    }

    func testRunImportAfterLink_cancellationDuringWait_stopsQuietly() async {
        ScriptedSyncURLProtocol.responses = [notReady()]
        let sut = makeSUT(sleep: { _ in throw CancellationError() })

        await sut.runImportAfterLink(itemID: Self.defaultItemID)

        XCTAssertEqual(ScriptedSyncURLProtocol.callCount, 1)
        XCTAssertNil(sut.presentedError)
        XCTAssertFalse(sut.isImporting)
    }

    func testRunImportAfterLink_itemUnlinkedDuringWait_stopsWithoutWriting() async throws {
        ScriptedSyncURLProtocol.responses = [notReady(), ready()]
        let linkedItemStore = StubLinkedItemStore(initial: LinkedItem(itemID: Self.defaultItemID, institutionName: "Test Bank", linkedAt: .now))
        let cursorStore = StubCursorStore()
        let recorder = SleepRecorder()
        let sut = makeSUT(cursorStore: cursorStore, linkedItemStore: linkedItemStore, sleep: recorder.sleep)
        recorder.onSleep = { _ in linkedItemStore.remove(itemID: Self.defaultItemID) }

        await sut.runImportAfterLink(itemID: Self.defaultItemID)

        XCTAssertEqual(ScriptedSyncURLProtocol.callCount, 1, "after the wait the item is gone: no further sync call at all.")
        XCTAssertEqual(recorder.durations.count, 1)
        XCTAssertTrue(try context.fetch(FetchDescriptor<SpendTransaction>()).isEmpty, "nothing may be inserted for an unlinked item.")
        XCTAssertNil(cursorStore.cursor(for: .sandbox, itemID: Self.defaultItemID), "no cursor may be written for an unlinked item.")
        XCTAssertNil(sut.presentedError)
        XCTAssertFalse(sut.isInitialDataPending)
        XCTAssertNil(sut.initialImportItemID)
    }

    func testRunImport_itemUnlinkedWhileRequestInFlight_discardsResponse() async throws {
        SlowSyncURLProtocol.response = ready()
        let linkedItemStore = StubLinkedItemStore(initial: LinkedItem(itemID: Self.defaultItemID, institutionName: "Test Bank", linkedAt: .now))
        let cursorStore = StubCursorStore()
        let sut = makeSUT(cursorStore: cursorStore, linkedItemStore: linkedItemStore, urlSession: makeSlowURLSession())

        let task = Task { await sut.runImport() }
        await Task.yield()
        linkedItemStore.remove(itemID: Self.defaultItemID)
        SlowSyncURLProtocol.gate.signal()
        await task.value

        XCTAssertTrue(try context.fetch(FetchDescriptor<SpendTransaction>()).isEmpty)
        XCTAssertNil(cursorStore.cursor(for: .sandbox, itemID: Self.defaultItemID))
        XCTAssertNil(sut.presentedError)
    }

    func testRunImport_cancelledRequest_returnsQuietlyWithoutError() async {
        ScriptedSyncURLProtocol.responses = [ready()]
        let sut = makeSUT(urlSession: makeCancelledURLSession())

        await sut.runImport()

        XCTAssertNil(sut.presentedError, "URLError.cancelled is not a user-facing failure.")
        XCTAssertNil(sut.presentedErrorDetail)
        XCTAssertFalse(sut.isImporting)
    }

    func testIsCancellation_recognizesCancellationErrorAndURLErrorCancelled() async {
        XCTAssertTrue(TransactionImportService.isCancellation(CancellationError()))
        XCTAssertTrue(TransactionImportService.isCancellation(URLError(.cancelled)))
        XCTAssertFalse(TransactionImportService.isCancellation(URLError(.notConnectedToInternet)))
    }

    func testRunImport_errorClearsStillFetchingFlag() async {
        // Same instance: flag set by a not-ready run, then cleared by a failing run.
        ScriptedSyncURLProtocol.responses = [notReady(), Data()]
        ScriptedSyncURLProtocol.statusCodes = [200, 500]
        let same = makeSUT()
        await same.runImport()
        XCTAssertTrue(same.isInitialDataPending)
        await same.runImport()
        XCTAssertNotNil(same.presentedError)
        XCTAssertFalse(same.isInitialDataPending, "\"Still fetching\" must not sit beside an error.")
    }

    func testRunImportAfterLink_syncsOnlyTheNewItem() async {
        ScriptedSyncURLProtocol.responses = [ready()]
        let linkedItemStore = StubLinkedItemStore(initial: LinkedItem(itemID: "item-1", institutionName: "Old", linkedAt: .now))
        linkedItemStore.save(LinkedItem(itemID: "item-2", institutionName: "New", linkedAt: .now))
        let cursorStore = StubCursorStore()
        let sut = makeSUT(cursorStore: cursorStore, linkedItemStore: linkedItemStore)

        await sut.runImportAfterLink(itemID: "item-2")

        XCTAssertEqual(ScriptedSyncURLProtocol.callCount, 1)
        XCTAssertNil(cursorStore.cursor(for: .sandbox, itemID: "item-1"))
        XCTAssertNotNil(cursorStore.cursor(for: .sandbox, itemID: "item-2"))
    }

    func testInitialImportItemID_isSetOnlyWhileLoopRuns() async {
        ScriptedSyncURLProtocol.responses = [notReady(), ready()]
        let recorder = SleepRecorder()
        let sut = makeSUT(sleep: recorder.sleep)
        var seen: String?
        recorder.onSleep = { _ in seen = sut.initialImportItemID }

        await sut.runImportAfterLink(itemID: Self.defaultItemID)

        XCTAssertEqual(seen, Self.defaultItemID)
        XCTAssertNil(sut.initialImportItemID)
    }
}
