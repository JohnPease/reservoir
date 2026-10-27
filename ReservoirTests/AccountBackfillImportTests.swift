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
        /// Runs (on the loading thread) once the request is recorded and before the response
        /// is delivered — lets a test mutate app state "while the request is in flight".
        nonisolated(unsafe) static var onRequest: ((Int) -> Void)?
        /// A scripted status of this value fails the request with `URLError.cancelled`.
        static let cancelledStatus = -999

        static func reset() { script = []; requestCursors = []; onRequest = nil }

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

            Self.onRequest?(Self.requestCursors.count)
            let index = min(Self.requestCursors.count - 1, max(Self.script.count - 1, 0))
            let entry = Self.script.isEmpty ? (status: 200, body: "{}") : Self.script[index]
            if entry.status == Self.cancelledStatus {
                client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
                return
            }
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
        let items: StubLinkedItemStore
    }

    private func makeHarness(
        storedCursor: String? = nil,
        backfillDone: Bool = false,
        modelContext: ModelContext? = nil
    ) -> Harness {
        let cursors = StubCursorStore()
        if let storedCursor { cursors.setCursor(storedCursor, for: .sandbox, itemID: Self.itemID) }
        let backfill = StubAccountBackfillStore()
        if backfillDone { backfill.setComplete(for: .sandbox, itemID: Self.itemID) }
        let accounts = StubLinkedAccountStore()
        let items = StubLinkedItemStore(initial: LinkedItem(itemID: Self.itemID, institutionName: "Test Bank", linkedAt: .now))
        let sut = TransactionImportService(
            modelContext: modelContext ?? context,
            keychain: StubKeychainWithToken(),
            urlSession: session(),
            environmentStore: StubEnvironmentStore(.sandbox),
            cursorStore: cursors,
            linkedItemStore: items,
            linkedAccountStore: accounts,
            backfillStore: backfill
        )
        return Harness(sut: sut, cursors: cursors, backfill: backfill, accounts: accounts, items: items)
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

    /// Everything about a row except its account, captured so a replay can be proven to have
    /// changed nothing else.
    private struct RowSnapshot: Equatable {
        let plaidTransactionID: String?
        let date: Date
        let merchantName: String
        let createdAt: Date
        let amount: Decimal
        let type: TransactionType
        let entryMethod: EntryMethod
        let isManualOverride: Bool
        let wasMergedFromManual: Bool
        let goalID: PersistentIdentifier?

        init(_ row: SpendTransaction) {
            plaidTransactionID = row.plaidTransactionID
            date = row.date
            merchantName = row.merchantName
            createdAt = row.createdAt
            amount = row.amount
            type = row.type
            entryMethod = row.entryMethod
            isManualOverride = row.isManualOverride
            wasMergedFromManual = row.wasMergedFromManual
            goalID = row.savingsGoal?.persistentModelID
        }
    }

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

        // Pre-state of EVERY replayed row (and the lookalike), compared field by field afterwards.
        let replayedRows = [overridden, merged, plain]
        let before = replayedRows.map(RowSnapshot.init)
        let lookalikeBefore = RowSnapshot(lookalikeManual)
        let pendingManualBefore = RowSnapshot(pendingManual)

        let replayPage = page(added: [
            tx("p-override", amount: 20, name: "Gym", account: "acc-A"),
            tx("p-merged", amount: 12.5, name: "Coffee Shop", account: "acc-B"),
            tx("p-plain", amount: 7, name: "Bakery", account: "acc-C"),
            tx("p-pending", amount: 33, name: "Pharmacy", account: "acc-D"),
        ], accounts: [acc("acc-A"), acc("acc-B")].joined(separator: ","))
        // Pass 1 (incremental from the old cursor) is empty; pass 2 is the stamp-only replay.
        ScriptedProtocol.script = [page(next: "inc-1"), replayPage]
        // Existing cursor but no backfill flag: this is the backfill.
        let h = makeHarness(storedCursor: "old-cursor")
        let queueBefore = h.sut.mergeQueue.map(\.id)

        await h.sut.runImport()

        XCTAssertEqual(ScriptedProtocol.requestCursors, ["old-cursor", nil], "incremental from the stored cursor, then the replay from nil.")
        XCTAssertEqual(try allTransactions().count, 5, "no row inserted, none replaced by unique-upsert.")
        XCTAssertEqual(try allPending().map(\.plaidTransactionID), ["p-pending"], "no new PendingTransactionMerge rows.")
        XCTAssertEqual(h.sut.mergeQueue.map(\.id), queueBefore, "no new merge prompts queued.")

        // Every replayed row: only plaidAccountID changed.
        XCTAssertEqual(replayedRows.map(RowSnapshot.init), before, "a replay must change nothing but plaidAccountID.")
        XCTAssertEqual(overridden.plaidAccountID, "acc-A")
        XCTAssertEqual(merged.plaidAccountID, "acc-B")
        XCTAssertEqual(plain.plaidAccountID, "acc-C")
        XCTAssertTrue(overridden.savingsGoal === goal)
        XCTAssertTrue(plain.savingsGoal === goal)

        XCTAssertEqual(RowSnapshot(lookalikeManual), lookalikeBefore, "replay must never merge a lookalike manual row.")
        XCTAssertNil(lookalikeManual.plaidAccountID)
        XCTAssertEqual(RowSnapshot(pendingManual), pendingManualBefore)
        XCTAssertEqual(try allPending().first?.plaidAccountID, "acc-D", "queued record is stamped, not duplicated.")
        XCTAssertEqual(h.sut.pendingMergeDecision?.incoming.accountID, "acc-D")
        XCTAssertEqual(h.sut.lastImportSummary?.added, 0)
        XCTAssertEqual(h.sut.lastImportSummary?.queuedForMerge, 0)
        XCTAssertEqual(h.cursors.cursor(for: .sandbox, itemID: Self.itemID), "inc-1", "the replay's cursor is never persisted.")
    }

    /// reservoir-j8t review (B): the replay used to run from a nil cursor through the normal
    /// insert path, re-adding every Plaid transaction with no local row - including ones the
    /// user deleted. The replay is now stamp-only.
    func test_replay_neverReinsertsLocallyDeletedOrNeverImportedTransactions() async throws {
        let kept = SpendTransaction(amount: 7, date: matchingDate, merchantName: "Bakery", type: .variable, entryMethod: .imported, plaidTransactionID: "p-kept", plaidItemID: Self.itemID)
        context.insert(kept)
        try context.save()
        // "p-deleted" was imported once and deleted by the user; "p-never" was never imported.
        // Both are in Plaid's full history, so both come back in the replay.
        ScriptedProtocol.script = [
            page(next: "inc-1"),
            page(added: [tx("p-deleted", account: "acc-1"), tx("p-kept", account: "acc-1"), tx("p-never", account: "acc-1")], next: "r1"),
        ]
        let h = makeHarness(storedCursor: "old-cursor")
        await h.sut.runImport()

        XCTAssertEqual(try allTransactions().compactMap(\.plaidTransactionID), ["p-kept"], "only the existing row is touched.")
        XCTAssertEqual(kept.plaidAccountID, "acc-1")
        XCTAssertTrue(h.backfill.isComplete(for: .sandbox, itemID: Self.itemID))
    }

    func test_replay_ignoresModifiedAndRemovedEntries() async throws {
        let row = SpendTransaction(amount: 10, date: matchingDate, merchantName: "Coffee Shop", type: .variable, entryMethod: .imported, plaidTransactionID: "p1", plaidItemID: Self.itemID)
        context.insert(row)
        try context.save()
        ScriptedProtocol.script = [
            page(next: "inc-1"),
            page(modified: [tx("p1", amount: 99, account: "acc-1")], removed: [#"{"transaction_id":"p1"}"#], next: "r1"),
        ]
        await makeHarness(storedCursor: "old-cursor").sut.runImport()
        XCTAssertEqual(try allTransactions().count, 1, "replay never deletes.")
        XCTAssertEqual(row.amount, 10, "replay never applies a modified entry.")
    }

    /// The incremental pass (from the stored cursor) applies new/modified/removed normally,
    /// so a transaction that changed since the old cursor is correct, and genuinely new
    /// transactions are kept - the replay can never lose them.
    func test_backfill_incrementalPassAppliesAddedModifiedRemoved_andReplayDoesNotRevertThem() async throws {
        let modifiedRow = SpendTransaction(amount: 10, date: matchingDate, merchantName: "Coffee Shop", type: .variable, entryMethod: .imported, plaidTransactionID: "p-mod", plaidItemID: Self.itemID)
        let removedRow = SpendTransaction(amount: 5, date: matchingDate, merchantName: "Gone", type: .variable, entryMethod: .imported, plaidTransactionID: "p-rem", plaidItemID: Self.itemID)
        context.insert(modifiedRow)
        context.insert(removedRow)
        try context.save()
        ScriptedProtocol.script = [
            page(added: [tx("p-new", amount: 3, name: "Newcomer", account: "acc-1")], modified: [tx("p-mod", amount: 11, account: "acc-1")], removed: [#"{"transaction_id":"p-rem"}"#], next: "inc-1"),
            // The replay snapshot reflects current Plaid state (no p-rem; p-mod at 11; p-new).
            page(added: [tx("p-mod", amount: 11, account: "acc-1"), tx("p-new", amount: 3, name: "Newcomer", account: "acc-1")], next: "r1"),
        ]
        let h = makeHarness(storedCursor: "old-cursor")
        await h.sut.runImport()

        XCTAssertEqual(Set(try allTransactions().compactMap(\.plaidTransactionID)), ["p-mod", "p-new"])
        XCTAssertEqual(modifiedRow.amount, 11)
        XCTAssertEqual(modifiedRow.plaidAccountID, "acc-1")
        XCTAssertEqual(try allTransactions().first { $0.plaidTransactionID == "p-new" }?.plaidAccountID, "acc-1")
        XCTAssertEqual(h.cursors.cursor(for: .sandbox, itemID: Self.itemID), "inc-1")
        XCTAssertEqual(h.sut.lastImportSummary?.added, 1)
        XCTAssertEqual(h.sut.lastImportSummary?.modified, 1)
        XCTAssertEqual(h.sut.lastImportSummary?.removed, 1)
    }

    func test_backfill_incrementalPassFailure_skipsReplayAndLeavesFlagUnset() async {
        ScriptedProtocol.script = [(500, "{}")]
        let h = makeHarness(storedCursor: "old-cursor")
        await h.sut.runImport()
        XCTAssertEqual(ScriptedProtocol.requestCursors, ["old-cursor"], "no replay after a failed incremental pass.")
        XCTAssertFalse(h.backfill.isComplete(for: .sandbox, itemID: Self.itemID))
        XCTAssertEqual(h.cursors.cursor(for: .sandbox, itemID: Self.itemID), "old-cursor")
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

    func test_backfill_unsetFlagWithStoredCursor_runsIncrementalThenReplaysFromNil_thenSetsFlag() async throws {
        ScriptedProtocol.script = [
            page(added: [tx("p1")], next: "i1"),
            page(added: [tx("p1")], next: "r1", hasMore: true),
            page(added: [tx("p2")], next: "r2", hasMore: false),
        ]
        let h = makeHarness(storedCursor: "old-cursor")
        XCTAssertFalse(h.sut.isAccountBackfillComplete)

        await h.sut.runImport()

        XCTAssertEqual(ScriptedProtocol.requestCursors, ["old-cursor", nil, "r1"])
        XCTAssertEqual(h.cursors.cursor(for: .sandbox, itemID: Self.itemID), "i1", "only the incremental pass persists a cursor.")
        XCTAssertEqual(try allTransactions().compactMap(\.plaidTransactionID), ["p1"], "the replay's p2 has no row and is not inserted.")
        XCTAssertTrue(h.backfill.isComplete(for: .sandbox, itemID: Self.itemID))
        XCTAssertTrue(h.sut.isAccountBackfillComplete)

        // Next run is a normal incremental sync from the persisted cursor.
        ScriptedProtocol.reset()
        ScriptedProtocol.script = [page(next: "i2")]
        await h.sut.runImport()
        XCTAssertEqual(ScriptedProtocol.requestCursors, ["i1"])
    }

    func test_backfill_interruptedReplay_leavesFlagUnset_thenRetriesIncrementalAndReplay() async {
        ScriptedProtocol.script = [
            page(next: "i1"),
            page(added: [tx("p1")], next: "r1", hasMore: true),
            (500, "{}"),
        ]
        let h = makeHarness(storedCursor: "old-cursor")
        await h.sut.runImport()

        XCTAssertEqual(h.cursors.cursor(for: .sandbox, itemID: Self.itemID), "i1", "the completed incremental pass advanced the cursor.")
        XCTAssertFalse(h.backfill.isComplete(for: .sandbox, itemID: Self.itemID))
        XCTAssertFalse(h.sut.isAccountBackfillComplete)

        ScriptedProtocol.reset()
        ScriptedProtocol.script = [page(next: "i2"), page(next: "r9")]
        await h.sut.runImport()
        XCTAssertEqual(ScriptedProtocol.requestCursors, ["i1", nil], "the retry runs incremental again, then a fresh replay from nil.")
        XCTAssertEqual(h.cursors.cursor(for: .sandbox, itemID: Self.itemID), "i2")
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

        // The interrupted fresh pass left a cursor but no flag: the next run continues from
        // that cursor, then stamp-replays from nil.
        ScriptedProtocol.reset()
        ScriptedProtocol.script = [page(next: "f2"), page(next: "f3")]
        await h.sut.runImport()
        XCTAssertEqual(ScriptedProtocol.requestCursors, ["f1", nil])
        XCTAssertEqual(h.cursors.cursor(for: .sandbox, itemID: Self.itemID), "f2")
        XCTAssertTrue(h.backfill.isComplete(for: .sandbox, itemID: Self.itemID))
    }

    // MARK: - Cancellation / unlink / not-ready never set the flag or write stale state

    func test_backfill_cancelledIncrementalPass_setsNoFlag_noErrorAndKeepsCursor() async {
        ScriptedProtocol.script = [(ScriptedProtocol.cancelledStatus, "")]
        let h = makeHarness(storedCursor: "old-cursor")
        await h.sut.runImport()
        XCTAssertNil(h.sut.presentedError, "a cancelled sync is not an error.")
        XCTAssertFalse(h.backfill.isComplete(for: .sandbox, itemID: Self.itemID))
        XCTAssertEqual(h.cursors.cursor(for: .sandbox, itemID: Self.itemID), "old-cursor")
        XCTAssertEqual(ScriptedProtocol.requestCursors.count, 1, "no replay after a cancelled pass.")
        XCTAssertFalse(h.sut.isAccountBackfillComplete)
    }

    func test_backfill_cancelledMidReplay_setsNoFlag_noError() async throws {
        ScriptedProtocol.script = [page(next: "i1"), page(added: [tx("p1")], next: "r1", hasMore: true), (ScriptedProtocol.cancelledStatus, "")]
        let h = makeHarness(storedCursor: "old-cursor")
        await h.sut.runImport()
        XCTAssertNil(h.sut.presentedError)
        XCTAssertFalse(h.backfill.isComplete(for: .sandbox, itemID: Self.itemID))
        XCTAssertEqual(h.cursors.cursor(for: .sandbox, itemID: Self.itemID), "i1")
        XCTAssertTrue(try allTransactions().isEmpty, "a replay never inserts.")
    }

    func test_unlinkWhileRequestInFlight_dropsResponse_noRowsAccountsCursorOrFlag() async throws {
        ScriptedProtocol.script = [page(added: [tx("p1", account: "acc-1")], accounts: acc("acc-1"), next: "c1")]
        let h = makeHarness()
        ScriptedProtocol.onRequest = { [items = h.items] _ in items.remove(itemID: Self.itemID) }
        await h.sut.runImport()

        XCTAssertEqual(ScriptedProtocol.requestCursors.count, 1)
        XCTAssertTrue(try allTransactions().isEmpty, "the unlinked item's response must not be written.")
        XCTAssertTrue(h.accounts.loadAll().isEmpty)
        XCTAssertNil(h.cursors.cursor(for: .sandbox, itemID: Self.itemID))
        XCTAssertFalse(h.backfill.isComplete(for: .sandbox, itemID: Self.itemID))
    }

    func test_unlinkDuringReplay_setsNoFlagAndStampsNothing() async throws {
        let row = SpendTransaction(amount: 7, date: matchingDate, merchantName: "Bakery", type: .variable, entryMethod: .imported, plaidTransactionID: "p1", plaidItemID: Self.itemID)
        context.insert(row)
        try context.save()
        ScriptedProtocol.script = [page(next: "i1"), page(added: [tx("p1", account: "acc-1")], next: "r1")]
        let h = makeHarness(storedCursor: "old-cursor")
        ScriptedProtocol.onRequest = { [items = h.items] count in
            if count == 2 { items.remove(itemID: Self.itemID) }
        }
        await h.sut.runImport()
        XCTAssertNil(row.plaidAccountID, "an unlinked item's replay response must not stamp rows.")
        XCTAssertFalse(h.backfill.isComplete(for: .sandbox, itemID: Self.itemID))
    }

    func test_refreshLinkedItemState_rereadsBackfillAndNeedsAttention() {
        let backfill = StubAccountBackfillStore()
        let items = StubLinkedItemStore()
        let sut = TransactionImportService(
            modelContext: context, keychain: StubKeychain(), urlSession: session(),
            environmentStore: StubEnvironmentStore(.sandbox), cursorStore: StubCursorStore(),
            linkedItemStore: items, linkedAccountStore: StubLinkedAccountStore(), backfillStore: backfill
        )
        XCTAssertTrue(sut.isAccountBackfillComplete)
        XCTAssertFalse(sut.needsAttention)
        items.save(LinkedItem(itemID: "x", institutionName: "X", linkedAt: .now, needsAttention: true))
        sut.refreshLinkedItemState()
        XCTAssertTrue(sut.isAccountBackfillComplete, "an item awaiting relink doesn't gate the budget.")
        XCTAssertTrue(sut.needsAttention)
        items.remove(itemID: "x")
        sut.refreshLinkedItemState()
        XCTAssertTrue(sut.isAccountBackfillComplete)
        XCTAssertFalse(sut.needsAttention)
    }

    // MARK: - Launch-time trigger (reservoir-0fq)

    func test_runAccountBackfillIfNeeded_runsWhenOwed_andCachesAccounts() async {
        // Pass 1 (incremental, no accounts listed), pass 2 (stamp-only replay lists them).
        ScriptedProtocol.script = [page(next: "cursor-inc"), page(accounts: acc("acc-1"), next: "cursor-replay")]
        let h = makeHarness(storedCursor: "old-cursor")
        XCTAssertTrue(h.sut.hasPendingAccountBackfill)
        XCTAssertTrue(h.accounts.loadAll().isEmpty)

        await h.sut.runAccountBackfillIfNeeded()

        XCTAssertEqual(h.accounts.loadAll().map(\.accountID), ["acc-1"], "the picker's account metadata must be cached after the launch-time run.")
        XCTAssertTrue(h.sut.isAccountBackfillComplete)
        XCTAssertFalse(h.sut.hasPendingAccountBackfill)
    }

    func test_runAccountBackfillIfNeeded_doesNothingWhenNotOwed() async {
        ScriptedProtocol.script = []
        let fresh = makeHarness(storedCursor: nil)
        XCTAssertFalse(fresh.sut.hasPendingAccountBackfill, "a fresh link (no cursor) is not owed a replay.")
        await fresh.sut.runAccountBackfillIfNeeded()
        let done = makeHarness(storedCursor: "c", backfillDone: true)
        XCTAssertFalse(done.sut.hasPendingAccountBackfill)
        await done.sut.runAccountBackfillIfNeeded()
        XCTAssertTrue(fresh.accounts.loadAll().isEmpty)
        XCTAssertTrue(done.accounts.loadAll().isEmpty)
    }

    func test_stuckStoredCursor_isDroppedAndItemResyncsFromTheBeginning() async throws {
        // Plaid rejects the stored cursor outright (4 attempts = first try + 3 restarts), then serves
        // the full history from a nil cursor, then the stamp-only replay.
        ScriptedProtocol.script = Array(repeating: mutationError(), count: 4) + [
            page(added: [tx("t1")], accounts: acc("acc-1"), next: "fresh-cursor"),
            page(added: [tx("t1")], accounts: acc("acc-1"), next: "replay-cursor")
        ]
        let h = makeHarness(storedCursor: "stuck-cursor")

        await h.sut.runImport()

        XCTAssertNil(h.sut.presentedError, "recovering from a stuck cursor must not surface an error.")
        XCTAssertEqual(h.cursors.cursor(for: .sandbox, itemID: Self.itemID), "fresh-cursor")
        XCTAssertEqual(try allTransactions().count, 1)
        XCTAssertEqual(try allTransactions().first?.plaidAccountID, "acc-1")
        XCTAssertEqual(h.accounts.loadAll().map(\.accountID), ["acc-1"])
        XCTAssertTrue(h.sut.isAccountBackfillComplete)
    }

    // MARK: - Gate excludes needs-attention items

    private func gateService(_ items: StubLinkedItemStore, _ backfill: StubAccountBackfillStore) -> TransactionImportService {
        TransactionImportService(
            modelContext: context, keychain: StubKeychain(), urlSession: session(),
            environmentStore: StubEnvironmentStore(.sandbox), cursorStore: StubCursorStore(),
            linkedItemStore: items, linkedAccountStore: StubLinkedAccountStore(), backfillStore: backfill
        )
    }

    func test_gate_healthyStillBackfilling_isNotComplete() {
        let items = StubLinkedItemStore()
        items.save(LinkedItem(itemID: "ok", institutionName: "OK", linkedAt: .now))
        items.save(LinkedItem(itemID: "bad", institutionName: "Bad", linkedAt: .now, needsAttention: true))
        let sut = gateService(items, StubAccountBackfillStore())
        XCTAssertFalse(sut.isAccountBackfillComplete, "a healthy item still backfilling keeps Syncing, even beside a needs-attention one.")
    }

    func test_gate_allItemsNeedAttention_isComplete() {
        let items = StubLinkedItemStore()
        items.save(LinkedItem(itemID: "a", institutionName: "A", linkedAt: .now, needsAttention: true))
        items.save(LinkedItem(itemID: "b", institutionName: "B", linkedAt: .now, needsAttention: true))
        XCTAssertTrue(gateService(items, StubAccountBackfillStore()).isAccountBackfillComplete)
    }

    func test_gate_recomputesWhenItemFlipsToNeedsAttentionAndBack() {
        let items = StubLinkedItemStore()
        let backfill = StubAccountBackfillStore()
        items.save(LinkedItem(itemID: "x", institutionName: "X", linkedAt: .now))
        let sut = gateService(items, backfill)
        XCTAssertFalse(sut.isAccountBackfillComplete)

        items.setNeedsAttention(true, itemID: "x")
        sut.refreshLinkedItemState()
        XCTAssertTrue(sut.isAccountBackfillComplete, "flipping to needs-attention stops gating.")

        items.setNeedsAttention(false, itemID: "x")
        sut.refreshLinkedItemState()
        XCTAssertFalse(sut.isAccountBackfillComplete, "after relink the unfinished backfill gates again.")

        backfill.setComplete(for: .sandbox, itemID: "x")
        sut.refreshAccountBackfillStatus()
        XCTAssertTrue(sut.isAccountBackfillComplete)
    }

    func test_gate_itemFlippedByFailedSync_recomputesImmediately() async {
        ScriptedProtocol.script = [(400, #"{"error_type":"ITEM_ERROR","error_code":"ITEM_LOGIN_REQUIRED","error_message":"x"}"#)]
        let h = makeHarness(storedCursor: "old-cursor")
        XCTAssertFalse(h.sut.isAccountBackfillComplete)
        await h.sut.runImport()
        XCTAssertTrue(h.sut.needsAttention)
        XCTAssertTrue(h.sut.isAccountBackfillComplete, "an item needing relink must not leave the budget stuck on Syncing.")
        XCTAssertFalse(h.backfill.isComplete(for: .sandbox, itemID: Self.itemID), "its backfill flag stays unset so it runs after relink.")
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

    func test_mutationDuringPagination_duringBackfill_restartsEachPassFromItsOwnStart() async {
        ScriptedProtocol.script = [
            page(added: [tx("p1")], next: "m1", hasMore: true),
            mutationError(),
            page(added: [tx("p1")], next: "m1b", hasMore: false),
            // Replay pass: also hit by a mutation, which restarts it from nil.
            page(added: [tx("p1")], next: "r1", hasMore: true),
            mutationError(),
            page(added: [tx("p1")], next: "r1b", hasMore: false),
        ]
        let h = makeHarness(storedCursor: "old")
        await h.sut.runImport()
        XCTAssertEqual(ScriptedProtocol.requestCursors, ["old", "m1", "old", nil, "r1", nil])
        XCTAssertEqual(h.cursors.cursor(for: .sandbox, itemID: Self.itemID), "m1b")
        XCTAssertTrue(h.backfill.isComplete(for: .sandbox, itemID: Self.itemID))
        XCTAssertNil(h.sut.presentedError)
    }

    func test_mutationDuringPagination_exhaustedRestarts_surfacesErrorAndKeepsFlagUnset() async {
        ScriptedProtocol.script = [mutationError()]
        let h = makeHarness(storedCursor: "old")
        await h.sut.runImport()
        // Exhausted restarts from the stored cursor, one more full set from a nil cursor (the
        // stuck-cursor recovery), then the error surfaces and the stored cursor is put back.
        XCTAssertEqual(ScriptedProtocol.requestCursors.count, 2 * (TransactionImportService.maxPaginationMutationRestarts + 1))
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

    // MARK: - Save failures roll back (read-only store)

    private var retainedContainers: [ModelContainer] = []

    /// Seeds a temp store through a writable context, then reopens it read-only so every
    /// `save()` the importer attempts throws. Returns the read-only context and the file URL
    /// (to read back what is really on disk).
    private func makeReadOnlyContext(seed: (ModelContext) throws -> Void) throws -> (context: ModelContext, url: URL) {
        let schema = Schema(versionedSchema: SchemaV9.self)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AccountBackfillImportTests-\(UUID().uuidString)")
            .appendingPathExtension("store")
        let seedContainer = try ModelContainer(
            for: schema, migrationPlan: ReservoirMigrationPlan.self,
            configurations: [ModelConfiguration(schema: schema, url: url)]
        )
        let seedContext = ModelContext(seedContainer)
        try seed(seedContext)
        try seedContext.save()
        retainedContainers.append(seedContainer)
        let readOnlyContainer = try ModelContainer(
            for: schema, migrationPlan: ReservoirMigrationPlan.self,
            configurations: [ModelConfiguration(schema: schema, url: url, allowsSave: false)]
        )
        retainedContainers.append(readOnlyContainer)
        return (ModelContext(readOnlyContainer), url)
    }

    private func onDisk<T: PersistentModel>(_ type: T.Type, at url: URL) throws -> [T] {
        let schema = Schema(versionedSchema: SchemaV9.self)
        let container = try ModelContainer(
            for: schema, migrationPlan: ReservoirMigrationPlan.self,
            configurations: [ModelConfiguration(schema: schema, url: url)]
        )
        retainedContainers.append(container)
        return try ModelContext(container).fetch(FetchDescriptor<T>())
    }

    private func seedManualWithPendingMerge(_ context: ModelContext) {
        let manual = SpendTransaction(amount: 12.5, date: matchingDate, merchantName: "Coffee Shop", type: .variable, entryMethod: .manual)
        context.insert(manual)
        context.insert(PendingTransactionMerge(plaidTransactionID: "p-pend", incomingAmount: 12.5, incomingDate: matchingDate, incomingMerchantName: "Coffee Shop", manualTransaction: manual, plaidItemID: Self.itemID, plaidAccountID: "acc-1"))
    }

    func test_stampSaveFailure_rollsBackAccountID_andLeavesFlagUnset() async throws {
        let (readOnly, _) = try makeReadOnlyContext { ctx in
            ctx.insert(SpendTransaction(amount: 7, date: self.matchingDate, merchantName: "Bakery", type: .variable, entryMethod: .imported, plaidTransactionID: "p1", plaidItemID: Self.itemID))
        }
        ScriptedProtocol.script = [page(next: "inc-1"), page(added: [tx("p1", account: "acc-1")], next: "r1")]
        let h = makeHarness(storedCursor: "old", modelContext: readOnly)
        await h.sut.runImport()

        let row = try XCTUnwrap(try readOnly.fetch(FetchDescriptor<SpendTransaction>()).first)
        XCTAssertNil(row.plaidAccountID, "a failed stamp save is rolled back.")
        XCTAssertFalse(h.backfill.isComplete(for: .sandbox, itemID: Self.itemID), "an unhandled replay page must not set the flag.")
    }

    func test_queueMergeSaveFailure_isUnhandled_doesNotAdvanceCursorOrQueue() async throws {
        let (readOnly, url) = try makeReadOnlyContext { ctx in
            ctx.insert(SpendTransaction(amount: 12.5, date: self.matchingDate, merchantName: "Coffee Shop", type: .variable, entryMethod: .manual))
        }
        ScriptedProtocol.script = [page(added: [tx("p1", account: "acc-1")], next: "c1")]
        let h = makeHarness(storedCursor: "old", backfillDone: true, modelContext: readOnly)
        await h.sut.runImport()

        XCTAssertTrue(h.sut.mergeQueue.isEmpty)
        XCTAssertEqual(h.cursors.cursor(for: .sandbox, itemID: Self.itemID), "old")
        XCTAssertTrue(try onDisk(PendingTransactionMerge.self, at: url).isEmpty)
    }

    func test_mergeResolutionSaveFailure_restoresManualRow() throws {
        let (readOnly, _) = try makeReadOnlyContext(seed: seedManualWithPendingMerge)
        let h = makeHarness(backfillDone: true, modelContext: readOnly)
        XCTAssertEqual(h.sut.mergeQueue.count, 1)
        let manual = try XCTUnwrap(try readOnly.fetch(FetchDescriptor<SpendTransaction>()).first)

        h.sut.resolveMergeDecision(.merge)

        XCTAssertEqual(manual.entryMethod, .manual)
        XCTAssertNil(manual.plaidTransactionID)
        XCTAssertFalse(manual.wasMergedFromManual)
        XCTAssertEqual(manual.plaidAccountID, nil)
    }

    func test_keepBothSaveFailure_persistsNothingAndKeepsTheRecord() throws {
        let (readOnly, url) = try makeReadOnlyContext(seed: seedManualWithPendingMerge)
        let h = makeHarness(backfillDone: true, modelContext: readOnly)
        h.sut.resolveMergeDecision(.keepBoth)

        XCTAssertEqual(try onDisk(SpendTransaction.self, at: url).count, 1, "no imported row reached disk.")
        XCTAssertEqual(try onDisk(PendingTransactionMerge.self, at: url).count, 1, "the decision record survives for a retry.")
    }

    func test_modifiedOnQueuedDecision_saveFailure_restoresRecordAndBlocksCursor() async throws {
        let (readOnly, _) = try makeReadOnlyContext(seed: seedManualWithPendingMerge)
        ScriptedProtocol.script = [page(modified: [tx("p-pend", amount: 99, account: "acc-9")], next: "c1")]
        let h = makeHarness(storedCursor: "old", backfillDone: true, modelContext: readOnly)
        await h.sut.runImport()

        let record = try XCTUnwrap(try readOnly.fetch(FetchDescriptor<PendingTransactionMerge>()).first)
        XCTAssertEqual(record.incomingAmount, 12.5)
        XCTAssertEqual(record.plaidAccountID, "acc-1")
        XCTAssertEqual(h.sut.mergeQueue.first?.incoming.amount, 12.5)
        XCTAssertEqual(h.cursors.cursor(for: .sandbox, itemID: Self.itemID), "old")
    }

    func test_removedOnQueuedDecision_saveFailure_keepsDecisionQueuedAndBlocksCursor() async throws {
        let (readOnly, _) = try makeReadOnlyContext(seed: seedManualWithPendingMerge)
        ScriptedProtocol.script = [page(removed: [#"{"transaction_id":"p-pend"}"#], next: "c1")]
        let h = makeHarness(storedCursor: "old", backfillDone: true, modelContext: readOnly)
        await h.sut.runImport()

        XCTAssertEqual(h.sut.mergeQueue.map(\.id), ["p-pend"])
        XCTAssertEqual(h.cursors.cursor(for: .sandbox, itemID: Self.itemID), "old")
    }

    func test_removedMergedRow_saveFailure_restoresImportedState() async throws {
        let (readOnly, _) = try makeReadOnlyContext { ctx in
            ctx.insert(SpendTransaction(amount: 12.5, date: self.matchingDate, merchantName: "Coffee Shop", type: .variable, entryMethod: .imported, plaidTransactionID: "p-m", plaidItemID: Self.itemID, plaidAccountID: "acc-1", wasMergedFromManual: true))
        }
        ScriptedProtocol.script = [page(removed: [#"{"transaction_id":"p-m"}"#], next: "c1")]
        let h = makeHarness(storedCursor: "old", backfillDone: true, modelContext: readOnly)
        await h.sut.runImport()

        let row = try XCTUnwrap(try readOnly.fetch(FetchDescriptor<SpendTransaction>()).first)
        XCTAssertEqual(row.entryMethod, .imported)
        XCTAssertEqual(row.plaidTransactionID, "p-m")
        XCTAssertEqual(row.plaidAccountID, "acc-1")
        XCTAssertTrue(row.wasMergedFromManual)
        XCTAssertEqual(h.cursors.cursor(for: .sandbox, itemID: Self.itemID), "old")
    }
}
