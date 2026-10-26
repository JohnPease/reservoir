import XCTest
import SwiftData
@testable import Reservoir

/// reservoir-j8t PR1: `account_id`/`accounts` capture, safe replay of `added`, and the
/// one-time per-item cursor-reset account backfill in `TransactionImportService`.
@MainActor
final class AccountBackfillImportTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private static let itemID = "item-1"

    override func setUpWithError() throws {
        let schema = Schema(versionedSchema: SchemaV9.self)
        container = try ModelContainer(
            for: schema, migrationPlan: ReservoirMigrationPlan.self,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        context = ModelContext(container)
        ScriptedProtocol.reset()
    }

    override func tearDownWithError() throws {
        context = nil
        container = nil
        ScriptedProtocol.reset()
    }

    // MARK: - Doubles / fixtures

    /// Serves queued `(status, body)` pairs in order (last repeats) and records the
    /// `cursor` each `/transactions/sync` request carried (`NSNull` -> nil).
    private final class ScriptedProtocol: URLProtocol {
        nonisolated(unsafe) static var script: [(status: Int, body: String)] = []
        nonisolated(unsafe) static var requestCursors: [String?] = []

        static func reset() { script = []; requestCursors = [] }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            var data = request.httpBody ?? Data()
            if data.isEmpty, let stream = request.httpBodyStream {
                stream.open()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let n = stream.read(&buffer, maxLength: buffer.count)
                    if n <= 0 { break }
                    data.append(buffer, count: n)
                }
                stream.close()
            }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            Self.requestCursors.append(json?["cursor"] as? String)

            let index = min(Self.requestCursors.count - 1, max(Self.script.count - 1, 0))
            let entry = Self.script.isEmpty ? (status: 200, body: "{}") : Self.script[index]
            let response = HTTPURLResponse(url: request.url!, statusCode: entry.status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(entry.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptedProtocol.self]
        return URLSession(configuration: configuration)
    }

    private struct Harness {
        let sut: TransactionImportService
        let cursors: StubCursorStore
        let backfill: StubAccountBackfillStore
        let accounts: StubLinkedAccountStore
    }

    private func makeHarness(
        storedCursor: String? = nil,
        backfillDone: Bool = false
    ) -> Harness {
        let cursors = StubCursorStore()
        if let storedCursor { cursors.setCursor(storedCursor, for: .sandbox, itemID: Self.itemID) }
        let backfill = StubAccountBackfillStore()
        if backfillDone { backfill.setComplete(for: .sandbox, itemID: Self.itemID) }
        let accounts = StubLinkedAccountStore()
        let sut = TransactionImportService(
            modelContext: context,
            keychain: StubKeychainWithToken(),
            urlSession: session(),
            environmentStore: StubEnvironmentStore(.sandbox),
            cursorStore: cursors,
            linkedItemStore: StubLinkedItemStore(initial: LinkedItem(itemID: Self.itemID, institutionName: "Test Bank", linkedAt: .now)),
            linkedAccountStore: accounts,
            backfillStore: backfill
        )
        return Harness(sut: sut, cursors: cursors, backfill: backfill, accounts: accounts)
    }

    private let dateString = "2026-07-16"

    private func tx(_ id: String, amount: Double = 12.5, name: String = "Coffee Shop", account: String? = "acc-1") -> String {
        let accountField = account.map { #","account_id":"\#($0)""# } ?? ""
        return #"{"transaction_id":"\#(id)","amount":\#(amount),"date":"\#(dateString)","merchant_name":"\#(name)","name":"\#(name)"\#(accountField)}"#
    }

    private func acc(_ id: String, name: String = "Checking") -> String {
        #"{"account_id":"\#(id)","name":"\#(name)","official_name":null,"mask":"0000","type":"depository","subtype":"checking"}"#
    }

    private func page(
        added: [String] = [], modified: [String] = [], removed: [String] = [],
        accounts: String? = nil, next: String = "cursor-next", hasMore: Bool = false
    ) -> (status: Int, body: String) {
        let accountsField = accounts.map { #","accounts":[\#($0)]"# } ?? ""
        return (200, #"{"added":[\#(added.joined(separator: ","))],"modified":[\#(modified.joined(separator: ","))],"removed":[\#(removed.joined(separator: ","))],"next_cursor":"\#(next)","has_more":\#(hasMore),"transactions_update_status":"HISTORICAL_UPDATE_COMPLETE"\#(accountsField)}"#)
    }

    private func mutationError() -> (status: Int, body: String) {
        (400, #"{"error_type":"TRANSACTIONS_ERROR","error_code":"TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION","error_message":"x"}"#)
    }

    private var matchingDate: Date {
        PlaidTransactionMapper.localDate(from: dateString, calendar: .current)!
    }

    private func allTransactions() throws -> [SpendTransaction] {
        try context.fetch(FetchDescriptor<SpendTransaction>())
    }

    private func allPending() throws -> [PendingTransactionMerge] {
        try context.fetch(FetchDescriptor<PendingTransactionMerge>())
    }

    // MARK: - Decoding

    func test_decode_accountIDIsOptionalOnTransactionsAndRemoved() throws {
        let with = try JSONDecoder().decode(PlaidTransaction.self, from: Data(tx("t1").utf8))
        XCTAssertEqual(with.account_id, "acc-1")
        let without = try JSONDecoder().decode(PlaidTransaction.self, from: Data(tx("t2", account: nil).utf8))
        XCTAssertNil(without.account_id)
        let removed = try JSONDecoder().decode(PlaidRemovedTransaction.self, from: Data(#"{"transaction_id":"t","account_id":"a"}"#.utf8))
        XCTAssertEqual(removed.account_id, "a")
        let removedOld = try JSONDecoder().decode(PlaidRemovedTransaction.self, from: Data(#"{"transaction_id":"t"}"#.utf8))
        XCTAssertNil(removedOld.account_id)
    }

    func test_decode_responseAccountsOptional() throws {
        let old = #"{"added":[],"modified":[],"removed":[],"next_cursor":"c","has_more":false}"#
        XCTAssertNil(try JSONDecoder().decode(PlaidSyncResponseBody.self, from: Data(old.utf8)).accounts)
        let withEmpty = page(accounts: "").body
        XCTAssertEqual(try JSONDecoder().decode(PlaidSyncResponseBody.self, from: Data(withEmpty.utf8)).accounts?.count, 0)
    }

    func test_mapper_carriesAccountID() throws {
        let dto = try JSONDecoder().decode(PlaidTransaction.self, from: Data(tx("t1", account: "acc-9").utf8))
        XCTAssertEqual(PlaidTransactionMapper.map(dto)?.accountID, "acc-9")
        let bare = try JSONDecoder().decode(PlaidTransaction.self, from: Data(tx("t2", account: nil).utf8))
        XCTAssertNil(PlaidTransactionMapper.map(bare)?.accountID)
    }

    // MARK: - Accounts merge across pages

    func test_accounts_mergeAcrossPages_andEmptyPageNeverDeletes() async {
        ScriptedProtocol.script = [
            page(accounts: acc("A"), next: "c1", hasMore: true),
            page(accounts: "", next: "c2", hasMore: true),
            page(accounts: acc("B", name: "Card"), next: "c3", hasMore: false),
        ]
        let h = makeHarness()
        await h.sut.runImport()
        XCTAssertEqual(Set(h.accounts.loadAll().map(\.accountID)), ["A", "B"])
        XCTAssertEqual(h.accounts.loadAll().first?.institutionName, "Test Bank")
        XCTAssertEqual(h.accounts.loadAll().first?.itemID, Self.itemID)

        // A later no-change sync returns `accounts: []` — nothing may be dropped.
        ScriptedProtocol.reset()
        ScriptedProtocol.script = [page(accounts: "", next: "c4")]
        await h.sut.runImport()
        XCTAssertEqual(Set(h.accounts.loadAll().map(\.accountID)), ["A", "B"])
    }

    // MARK: - Stamping

    func test_newImport_stampsAccountID() async throws {
        ScriptedProtocol.script = [page(added: [tx("p1", account: "acc-7")], accounts: acc("acc-7"))]
        await makeHarness().sut.runImport()
        let rows = try allTransactions()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.plaidAccountID, "acc-7")
    }

    func test_dedupQueue_recordsAccount_thenKeepBothStampsNewRow() async throws {
        let manual = SpendTransaction(amount: 12.5, date: matchingDate, merchantName: "Coffee Shop", type: .variable, entryMethod: .manual)
        context.insert(manual)
        try context.save()
        ScriptedProtocol.script = [page(added: [tx("p1", account: "acc-7")])]
        let h = makeHarness(backfillDone: true)
        await h.sut.runImport()

        XCTAssertEqual(try allPending().first?.plaidAccountID, "acc-7")
        h.sut.resolveMergeDecision(.keepBoth)

        let imported = try allTransactions().first { $0.entryMethod == .imported }
        XCTAssertEqual(imported?.plaidAccountID, "acc-7")
        XCTAssertNil(manual.plaidAccountID)
        XCTAssertTrue(try allPending().isEmpty)
    }

    func test_merge_stampsAccountOntoManualRow_andRehydratedQueueKeepsIt() async throws {
        let manual = SpendTransaction(amount: 12.5, date: matchingDate, merchantName: "Coffee Shop", type: .variable, entryMethod: .manual)
        context.insert(manual)
        try context.save()
        ScriptedProtocol.script = [page(added: [tx("p1", account: "acc-7")])]
        let h = makeHarness(backfillDone: true)
        await h.sut.runImport()

        // A fresh service instance re-hydrates the queue from the persisted record.
        let rehydrated = makeHarness(backfillDone: true).sut
        XCTAssertEqual(rehydrated.pendingMergeDecision?.incoming.accountID, "acc-7")
        rehydrated.resolveMergeDecision(.merge)

        XCTAssertEqual(manual.plaidAccountID, "acc-7")
        XCTAssertTrue(manual.wasMergedFromManual)
    }

    func test_applyMerge_doesNotOverwriteExistingAccount() {
        let manual = SpendTransaction(amount: 1, date: .now, merchantName: "M", type: .variable, entryMethod: .manual, plaidAccountID: "keep")
        TransactionDedupMatcher.applyMerge(to: manual, incoming: MappedPlaidTransaction(plaidTransactionID: "p", amount: 1, date: .now, merchantName: "M", accountID: "other"))
        XCTAssertEqual(manual.plaidAccountID, "keep")
    }

    func test_modified_stampsWhenNilAndUpdatesWhenProvided() async throws {
        let row = SpendTransaction(amount: 10, date: matchingDate, merchantName: "Coffee Shop", type: .variable, entryMethod: .imported, plaidTransactionID: "p1", plaidItemID: Self.itemID)
        context.insert(row)
        try context.save()
        ScriptedProtocol.script = [page(modified: [tx("p1", amount: 11, account: "acc-3")])]
        await makeHarness(backfillDone: true).sut.runImport()
        XCTAssertEqual(row.plaidAccountID, "acc-3")
        XCTAssertEqual(row.amount, 11)
    }

    // MARK: - Safe replay

    func test_replay_changesOnlyPlaidAccountID_noNewRowsNoPromptsNoOverrideLoss() async throws {
        let goal = SavingsGoal(
            targetAmount: 1000, targetDate: Calendar.current.date(byAdding: .day, value: 30, to: .now)!,
            startDate: .now, startingBalance: 0, dailyBase: 30
        )
        context.insert(goal)
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        // An override row, a merged-from-manual row, and a goal-linked plain import; none has an account yet.
        let overridden = SpendTransaction(amount: 20, date: matchingDate, merchantName: "Gym", type: .fixed, entryMethod: .imported, plaidTransactionID: "p-override", plaidItemID: Self.itemID, isManualOverride: true, savingsGoal: goal, createdAt: created)
        let merged = SpendTransaction(amount: 12.5, date: matchingDate, merchantName: "Coffee Shop", type: .fixed, entryMethod: .imported, plaidTransactionID: "p-merged", plaidItemID: Self.itemID, isManualOverride: true, createdAt: created, wasMergedFromManual: true)
        let plain = SpendTransaction(amount: 7, date: matchingDate, merchantName: "Bakery", type: .variable, entryMethod: .imported, plaidTransactionID: "p-plain", plaidItemID: Self.itemID, savingsGoal: goal, createdAt: created)
        // A manual row with a pending merge awaiting the user, and a *different* manual row that
        // would dedup-match a replayed already-imported transaction if replay reached the matcher.
        let pendingManual = SpendTransaction(amount: 33, date: matchingDate, merchantName: "Pharmacy", type: .variable, entryMethod: .manual)
        let lookalikeManual = SpendTransaction(amount: 7, date: matchingDate, merchantName: "Bakery", type: .variable, entryMethod: .manual)
        [overridden, merged, plain, pendingManual, lookalikeManual].forEach(context.insert)
        context.insert(PendingTransactionMerge(plaidTransactionID: "p-pending", incomingAmount: 33, incomingDate: matchingDate, incomingMerchantName: "Pharmacy", manualTransaction: pendingManual, plaidItemID: Self.itemID))
        try context.save()

        ScriptedProtocol.script = [page(added: [
            tx("p-override", amount: 20, name: "Gym", account: "acc-A"),
            tx("p-merged", amount: 12.5, name: "Coffee Shop", account: "acc-B"),
            tx("p-plain", amount: 7, name: "Bakery", account: "acc-C"),
            tx("p-pending", amount: 33, name: "Pharmacy", account: "acc-D"),
        ], accounts: [acc("acc-A"), acc("acc-B")].joined(separator: ","))]
        // Existing cursor but no backfill flag: this is the backfill replay.
        let h = makeHarness(storedCursor: "old-cursor")
        let queueBefore = h.sut.mergeQueue.map(\.id)

        await h.sut.runImport()

        XCTAssertNil(ScriptedProtocol.requestCursors.first!, "backfill replays from a nil cursor.")
        XCTAssertEqual(try allTransactions().count, 5, "no row inserted, none replaced by unique-upsert.")
        XCTAssertEqual(try allPending().map(\.plaidTransactionID), ["p-pending"], "no new PendingTransactionMerge rows.")
        XCTAssertEqual(h.sut.mergeQueue.map(\.id), queueBefore, "no new merge prompts queued.")

        XCTAssertEqual(overridden.plaidAccountID, "acc-A")
        XCTAssertEqual(overridden.type, .fixed)
        XCTAssertTrue(overridden.isManualOverride)
        XCTAssertTrue(overridden.savingsGoal === goal)
        XCTAssertEqual(overridden.createdAt, created)
        XCTAssertEqual(overridden.amount, 20)

        XCTAssertEqual(merged.plaidAccountID, "acc-B")
        XCTAssertTrue(merged.wasMergedFromManual)
        XCTAssertTrue(merged.isManualOverride)
        XCTAssertEqual(merged.type, .fixed)
        XCTAssertEqual(merged.entryMethod, .imported)

        XCTAssertEqual(plain.plaidAccountID, "acc-C")
        XCTAssertTrue(plain.savingsGoal === goal)
        XCTAssertEqual(plain.type, .variable)

        XCTAssertEqual(lookalikeManual.entryMethod, .manual, "replay must never merge a lookalike manual row.")
        XCTAssertNil(lookalikeManual.plaidAccountID)
        XCTAssertEqual(pendingManual.entryMethod, .manual)
        XCTAssertEqual(try allPending().first?.plaidAccountID, "acc-D", "queued record is stamped, not duplicated.")
        XCTAssertEqual(h.sut.pendingMergeDecision?.incoming.accountID, "acc-D")
        XCTAssertEqual(h.sut.lastImportSummary?.added, 0)
        XCTAssertEqual(h.sut.lastImportSummary?.queuedForMerge, 0)
    }

    func test_replay_neverOverwritesNonNilAccountID() async throws {
        let row = SpendTransaction(amount: 12.5, date: matchingDate, merchantName: "Coffee Shop", type: .variable, entryMethod: .imported, plaidTransactionID: "p1", plaidItemID: Self.itemID, plaidAccountID: "original")
        context.insert(row)
        try context.save()
        ScriptedProtocol.script = [page(added: [tx("p1", account: "different")])]
        await makeHarness(storedCursor: "old").sut.runImport()
        XCTAssertEqual(row.plaidAccountID, "original")
        XCTAssertEqual(try allTransactions().count, 1)
    }

    func test_replay_isIdempotentAcrossRepeatedPasses() async throws {
        ScriptedProtocol.script = [page(added: [tx("p1", account: "acc-1")])]
        let h = makeHarness()
        await h.sut.runImport()
        await h.sut.runImport()
        XCTAssertEqual(try allTransactions().count, 1)
        XCTAssertTrue(try allPending().isEmpty)
    }

    // MARK: - Backfill lifecycle

    func test_backfill_unsetFlagWithStoredCursor_replaysFromNil_thenSwapsCursorAndSetsFlag() async {
        ScriptedProtocol.script = [
            page(added: [tx("p1")], next: "r1", hasMore: true),
            page(added: [tx("p2")], next: "r2", hasMore: false),
        ]
        let h = makeHarness(storedCursor: "old-cursor")
        XCTAssertFalse(h.sut.isAccountBackfillComplete)

        await h.sut.runImport()

        XCTAssertEqual(ScriptedProtocol.requestCursors.count, 2)
        XCTAssertNil(ScriptedProtocol.requestCursors[0])
        XCTAssertEqual(ScriptedProtocol.requestCursors[1], "r1")
        XCTAssertEqual(h.cursors.cursor(for: .sandbox, itemID: Self.itemID), "r2")
        XCTAssertTrue(h.backfill.isComplete(for: .sandbox, itemID: Self.itemID))
        XCTAssertTrue(h.sut.isAccountBackfillComplete)

        // Next run is a normal incremental sync from the new cursor.
        ScriptedProtocol.reset()
        ScriptedProtocol.script = [page(next: "r3")]
        await h.sut.runImport()
        XCTAssertEqual(ScriptedProtocol.requestCursors, ["r2"])
    }

    func test_backfill_interruptedPass_keepsOldCursorAndLeavesFlagUnset_thenRetriesFromNil() async {
        ScriptedProtocol.script = [
            page(added: [tx("p1")], next: "r1", hasMore: true),
            (500, "{}"),
        ]
        let h = makeHarness(storedCursor: "old-cursor")
        await h.sut.runImport()

        XCTAssertEqual(h.cursors.cursor(for: .sandbox, itemID: Self.itemID), "old-cursor", "old cursor survives an interrupted replay.")
        XCTAssertFalse(h.backfill.isComplete(for: .sandbox, itemID: Self.itemID))
        XCTAssertFalse(h.sut.isAccountBackfillComplete)

        ScriptedProtocol.reset()
        ScriptedProtocol.script = [page(added: [tx("p1")], next: "r9")]
        await h.sut.runImport()
        XCTAssertNil(ScriptedProtocol.requestCursors[0], "the retry restarts from nil.")
        XCTAssertEqual(h.cursors.cursor(for: .sandbox, itemID: Self.itemID), "r9")
        XCTAssertTrue(h.backfill.isComplete(for: .sandbox, itemID: Self.itemID))
    }

    func test_backfill_freshLink_setsFlagOnCompletion_midPassDoesNot() async {
        ScriptedProtocol.script = [
            page(added: [tx("p1")], next: "f1", hasMore: true),
            (500, "{}"),
        ]
        let h = makeHarness()
        await h.sut.runImport()
        XCTAssertFalse(h.backfill.isComplete(for: .sandbox, itemID: Self.itemID))
        XCTAssertEqual(h.cursors.cursor(for: .sandbox, itemID: Self.itemID), "f1", "a fresh pass persists cursors per page as before.")

        // The interrupted fresh pass left a cursor but no flag, so it is replayed from nil.
        ScriptedProtocol.reset()
        ScriptedProtocol.script = [page(next: "f2")]
        await h.sut.runImport()
        XCTAssertNil(ScriptedProtocol.requestCursors[0])
        XCTAssertTrue(h.backfill.isComplete(for: .sandbox, itemID: Self.itemID))
    }

    func test_backfill_notReadyEmptyPage_doesNotSetFlag() async {
        ScriptedProtocol.script = [(200, #"{"added":[],"modified":[],"removed":[],"next_cursor":"","has_more":false,"transactions_update_status":"NOT_READY"}"#)]
        let h = makeHarness()
        await h.sut.runImport()
        XCTAssertFalse(h.backfill.isComplete(for: .sandbox, itemID: Self.itemID))
    }

    func test_isAccountBackfillComplete_vacuouslyTrueWithNoItems_andRefreshes() {
        let backfill = StubAccountBackfillStore()
        let items = StubLinkedItemStore()
        let sut = TransactionImportService(
            modelContext: context, keychain: StubKeychain(), urlSession: session(),
            environmentStore: StubEnvironmentStore(.sandbox), cursorStore: StubCursorStore(),
            linkedItemStore: items, linkedAccountStore: StubLinkedAccountStore(), backfillStore: backfill
        )
        XCTAssertTrue(sut.isAccountBackfillComplete)
        items.save(LinkedItem(itemID: "x", institutionName: "X", linkedAt: .now))
        sut.refreshAccountBackfillStatus()
        XCTAssertFalse(sut.isAccountBackfillComplete)
        backfill.setComplete(for: .sandbox, itemID: "x")
        sut.refreshAccountBackfillStatus()
        XCTAssertTrue(sut.isAccountBackfillComplete)
    }

    // MARK: - Mutation during pagination

    func test_mutationDuringPagination_restartsFromPaginationStart_withoutSurfacingErrorOrSettingFlagEarly() async throws {
        ScriptedProtocol.script = [
            page(added: [tx("p1")], next: "m1", hasMore: true),
            mutationError(),
            page(added: [tx("p1"), tx("p2")], next: "m1b", hasMore: true),
            page(added: [tx("p3")], next: "m2", hasMore: false),
        ]
        let h = makeHarness(storedCursor: "start", backfillDone: true)

        await h.sut.runImport()

        XCTAssertEqual(ScriptedProtocol.requestCursors, ["start", "m1", "start", "m1b"])
        XCTAssertNil(h.sut.presentedError)
        XCTAssertEqual(h.cursors.cursor(for: .sandbox, itemID: Self.itemID), "m2")
        XCTAssertEqual(Set(try allTransactions().compactMap(\.plaidTransactionID)), ["p1", "p2", "p3"])
        XCTAssertEqual(try allTransactions().count, 3, "restarted pages replay safely - no duplicate rows.")
    }

    func test_mutationDuringPagination_duringBackfill_restartsFromNilAndLeavesFlagUnsetUntilComplete() async {
        ScriptedProtocol.script = [
            page(added: [tx("p1")], next: "m1", hasMore: true),
            mutationError(),
            page(added: [tx("p1")], next: "m1b", hasMore: false),
        ]
        let h = makeHarness(storedCursor: "old")
        await h.sut.runImport()
        XCTAssertEqual(ScriptedProtocol.requestCursors.count, 3)
        XCTAssertNil(ScriptedProtocol.requestCursors[0])
        XCTAssertNil(ScriptedProtocol.requestCursors[2], "restart goes back to the replay's nil start.")
        XCTAssertEqual(h.cursors.cursor(for: .sandbox, itemID: Self.itemID), "m1b")
        XCTAssertTrue(h.backfill.isComplete(for: .sandbox, itemID: Self.itemID))
    }

    func test_mutationDuringPagination_exhaustedRestarts_surfacesErrorAndKeepsFlagUnset() async {
        ScriptedProtocol.script = [mutationError()]
        let h = makeHarness(storedCursor: "old")
        await h.sut.runImport()
        XCTAssertEqual(ScriptedProtocol.requestCursors.count, TransactionImportService.maxPaginationMutationRestarts + 1)
        XCTAssertNotNil(h.sut.presentedError)
        XCTAssertEqual(h.cursors.cursor(for: .sandbox, itemID: Self.itemID), "old")
        XCTAssertFalse(h.backfill.isComplete(for: .sandbox, itemID: Self.itemID))
    }

    // MARK: - Orphan cleanup also clears backfill flags / accounts

    func test_removeOrphaned_clearsBackfillFlagAndAccountsForUnlinkedItems() {
        let cursors = StubCursorStore()
        cursors.setCursor("c", for: .sandbox, itemID: "gone")
        let backfill = StubAccountBackfillStore()
        backfill.setComplete(for: .sandbox, itemID: "gone")
        let accounts = StubLinkedAccountStore()
        accounts.upsert([LinkedAccount(accountID: "a", itemID: "gone", name: "n", type: "depository")])
        let sut = TransactionImportService(
            modelContext: context, keychain: StubKeychain(), urlSession: session(),
            environmentStore: StubEnvironmentStore(.sandbox), cursorStore: cursors,
            linkedItemStore: StubLinkedItemStore(), linkedAccountStore: accounts, backfillStore: backfill
        )
        XCTAssertNil(sut.removeOrphanedLocalData())
        XCTAssertFalse(backfill.isComplete(for: .sandbox, itemID: "gone"))
        XCTAssertTrue(accounts.loadAll().isEmpty)
    }
}
