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
        let schema = Schema(versionedSchema: SchemaV5.self)
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

    private func makeSUT(
        keychain: KeychainServicing = StubKeychainWithToken(),
        cursorStore: PlaidSyncCursorStoring = StubCursorStore(),
        linkedItemStore: LinkedItemStoring = StubLinkedItemStore(),
        urlSession: URLSession? = nil
    ) -> TransactionImportService {
        TransactionImportService(
            modelContext: context,
            keychain: keychain,
            urlSession: urlSession ?? makeScriptedURLSession(),
            environmentStore: StubEnvironmentStore(.sandbox),
            cursorStore: cursorStore,
            linkedItemStore: linkedItemStore
        )
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

    private func syncResponse(added: [String] = [], modified: [String] = [], removed: [String] = [], nextCursor: String, hasMore: Bool = false) -> Data {
        let json = """
        {"added": [\(added.joined(separator: ","))], "modified": [\(modified.joined(separator: ","))], "removed": [\(removed.joined(separator: ","))], "next_cursor": "\(nextCursor)", "has_more": \(hasMore)}
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
        XCTAssertEqual(cursorStore.cursor(for: .sandbox), "cursor-after-queue")
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

    // MARK: - Goal attribution

    func testRunImport_zeroActiveGoals_savesUnattributed() async throws {
        ScriptedSyncURLProtocol.responses = [
            syncResponse(added: [transactionJSON(id: "plaid-1", amount: 12.50)], nextCursor: "cursor-1")
        ]
        let sut = makeSUT()
        await sut.runImport()

        let fetched = try context.fetch(FetchDescriptor<SpendTransaction>())
        XCTAssertNil(fetched.first?.savingsGoal)
    }

    func testRunImport_oneActiveGoal_autoAttributes() async throws {
        let goal = makeGoal()
        context.insert(goal)
        try context.save()

        ScriptedSyncURLProtocol.responses = [
            syncResponse(added: [transactionJSON(id: "plaid-1", amount: 12.50)], nextCursor: "cursor-1")
        ]
        let sut = makeSUT()
        await sut.runImport()

        let fetched = try context.fetch(FetchDescriptor<SpendTransaction>())
        XCTAssertEqual(fetched.first?.savingsGoal?.persistentModelID, goal.persistentModelID)
    }

    func testRunImport_twoActiveGoals_savesUnattributed() async throws {
        context.insert(makeGoal())
        context.insert(makeGoal())
        try context.save()

        ScriptedSyncURLProtocol.responses = [
            syncResponse(added: [transactionJSON(id: "plaid-1", amount: 12.50)], nextCursor: "cursor-1")
        ]
        let sut = makeSUT()
        await sut.runImport()

        let fetched = try context.fetch(FetchDescriptor<SpendTransaction>())
        XCTAssertNil(fetched.first?.savingsGoal)
    }

    func testResolveMergeDecision_keepBoth_appliesSameGoalAttributionPolicy() async throws {
        let goal = makeGoal()
        context.insert(goal)
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
        let newImported = fetched.first { $0.plaidTransactionID == "plaid-1" }
        XCTAssertEqual(newImported?.savingsGoal?.persistentModelID, goal.persistentModelID)
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
        let schema = Schema(versionedSchema: SchemaV5.self)
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
            cursorStore: cursorStore
        )

        await sut.runImport()

        XCTAssertNil(cursorStore.cursor(for: .sandbox), "A page with a genuine save failure must not advance the cursor.")
        XCTAssertEqual(sut.lastImportSummary?.added, 0, "Neither failed write counts toward the summary.")

        // Verify against a *fresh* container reopened from the same store file, rather
        // than the same in-memory `readOnlyContext` — a rolled-back insert/delete pair
        // within one context's pending changes isn't a reliable signal to assert on
        // directly (SwiftData's in-memory change tracking around a read-only store has
        // sharp edges independent of what this test cares about), but what actually
        // landed on disk is the real question this test needs answered.
        let verificationSchema = Schema(versionedSchema: SchemaV5.self)
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
            cursorStore: StubCursorStore()
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
        XCTAssertEqual(linkedItemStore.load()?.needsAttention, true)
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

        linkedItemStore.setNeedsAttention(false)
        sut.refreshNeedsAttention()

        XCTAssertFalse(sut.needsAttention)
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
        linkedItemStore.clear()

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
        XCTAssertEqual(cursorStore.cursor(for: .sandbox), "cursor-page2")
        let fetched = try context.fetch(FetchDescriptor<SpendTransaction>())
        XCTAssertEqual(fetched.count, 2)
        XCTAssertEqual(sut.lastImportSummary?.added, 2)
    }
}
