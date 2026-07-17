import XCTest
import SwiftData
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
    }

    override func tearDownWithError() throws {
        context = nil
        container = nil
        ScriptedSyncURLProtocol.reset()
    }

    // MARK: - Test doubles

    /// Returns each queued response in order for successive `/transactions/sync` calls
    /// (one call per page); the last queued response repeats if more calls happen than
    /// responses were scripted.
    private final class ScriptedSyncURLProtocol: URLProtocol {
        nonisolated(unsafe) static var responses: [Data] = []
        nonisolated(unsafe) static var callCount = 0

        static func reset() {
            responses = []
            callCount = 0
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let index = min(Self.callCount, max(Self.responses.count - 1, 0))
            Self.callCount += 1
            let body = Self.responses.isEmpty ? Data() : Self.responses[index]
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

    private func makeScriptedURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptedSyncURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeSUT(
        keychain: KeychainServicing = StubKeychainWithToken(),
        cursorStore: PlaidSyncCursorStoring = StubCursorStore()
    ) -> TransactionImportService {
        TransactionImportService(
            modelContext: context,
            keychain: keychain,
            urlSession: makeScriptedURLSession(),
            environmentStore: StubEnvironmentStore(.sandbox),
            cursorStore: cursorStore
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
