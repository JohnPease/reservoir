import Foundation
import Observation
import SwiftData
import OSLog

// MARK: - /transactions/sync wire types

/// Mirrors Plaid's documented `/transactions/sync` transaction object shape, keeping
/// only the fields this app maps (`PlaidTransactionMapper`). Property names match
/// Plaid's JSON keys directly (snake_case), same convention as `PlaidServiceLive`'s
/// per-call-site request/response structs — no `keyDecodingStrategy` needed.
struct PlaidTransaction: Decodable {
    let transaction_id: String
    let amount: Decimal
    let date: String
    let merchant_name: String?
    let name: String
}

/// Plaid's `/transactions/sync` `removed` list entries — just the ID of a transaction
/// that no longer exists on Plaid's side.
struct PlaidRemovedTransaction: Decodable {
    let transaction_id: String
}

struct PlaidSyncRequestBody: Encodable {
    let client_id: String
    let secret: String
    let access_token: String
    let cursor: String?
    let count: Int
}

struct PlaidSyncResponseBody: Decodable {
    let added: [PlaidTransaction]
    let modified: [PlaidTransaction]
    let removed: [PlaidRemovedTransaction]
    let next_cursor: String
    let has_more: Bool
}

/// A lightweight, non-blocking summary of what one `runImport()` call did — this story's
/// UX section calls for a brief confirmation ("3 new transactions") rather than a
/// dedicated summary screen; this is the data backing that copy.
struct ImportSummary: Equatable {
    var added = 0
    var modified = 0
    var removed = 0
    var queuedForMerge = 0

    var isEmpty: Bool { added == 0 && modified == 0 && removed == 0 && queuedForMerge == 0 }
}

/// Orchestrates a Plaid `/transactions/sync`-based import (adq.6.3): fetches new/changed/
/// removed transactions since the last successful sync, maps them, runs dedup detection
/// against existing manual entries, applies `MerchantMatcher` auto-tagging, and either
/// saves directly or queues a merge-prompt decision. `@Observable @MainActor`, same idiom
/// as `PlaidServiceLive` (`presentedError`/`retry()` there maps to
/// `pendingMergeDecision`/`resolveMergeDecision(_:)` here).
///
/// Takes `ModelContext` directly and performs its own internal `FetchDescriptor` fetches
/// rather than requiring a caller to pass in already-`@Query`'d arrays — this story's
/// debug trigger is view-driven, but adq.6.4 will call `runImport()` from app-lifecycle
/// events where no view may be presenting `@Query` results.
@Observable
@MainActor
final class TransactionImportService {
    private(set) var isImporting = false
    var presentedError: PlaidErrorCategory?
    private(set) var lastImportSummary: ImportSummary?
    private(set) var mergeQueue: [PendingMergeDecision] = []
    var pendingMergeDecision: PendingMergeDecision? { mergeQueue.first }

    struct PendingMergeDecision: Identifiable, Equatable {
        let id: String
        let manualTransaction: SpendTransaction
        let incoming: MappedPlaidTransaction

        static func == (lhs: PendingMergeDecision, rhs: PendingMergeDecision) -> Bool {
            lhs.id == rhs.id
        }
    }

    enum MergeChoice {
        case merge
        case keepBoth
    }

    private let modelContext: ModelContext
    private let keychain: KeychainServicing
    private let urlSession: URLSession
    private let environmentStore: PlaidEnvironmentStoring
    private let cursorStore: PlaidSyncCursorStoring
    private let logger: Logger

    init(
        modelContext: ModelContext,
        keychain: KeychainServicing = KeychainService(),
        urlSession: URLSession = .shared,
        environmentStore: PlaidEnvironmentStoring = PlaidEnvironmentStore(),
        cursorStore: PlaidSyncCursorStoring = PlaidSyncCursorStore(),
        logger: Logger = Logger(subsystem: "com.reservoir.app", category: "TransactionImportService")
    ) {
        self.modelContext = modelContext
        self.keychain = keychain
        self.urlSession = urlSession
        self.environmentStore = environmentStore
        self.cursorStore = cursorStore
        self.logger = logger
    }

    // MARK: - Import

    /// Runs a full sync: pages through `/transactions/sync` while `has_more`, processing
    /// each page's `added`/`modified`/`removed` lists before persisting the cursor past
    /// that page. A page's cursor only advances once every item in it either saved
    /// successfully or was queued for a merge decision — a **queued** item counts as
    /// handled (Plaid won't redeliver an already-acknowledged `added` item once the
    /// cursor moves past it), but a genuine `saveOrRollback`/`deleteWithRollback` failure
    /// blocks the advance so that item is retried on the next sync rather than silently
    /// skipped forever. A page with unhandled failures stops pagination for this run
    /// (later pages would only be re-fetched next run anyway, since the persisted cursor
    /// hasn't moved past the failed page).
    func runImport() async {
        guard !isImporting else { return }
        isImporting = true
        defer { isImporting = false }

        presentedError = nil

        guard let accessToken = try? await keychain.read(for: PlaidKeychainKey.accessToken) else {
            // No linked item yet, or the keychain read failed — nothing to import,
            // not an error surfaced to the user (background operation).
            return
        }

        let environment = environmentStore.current
        var requestCursor = cursorStore.cursor(for: environment)
        var summary = ImportSummary()
        var manualTransactions = fetchManualTransactions()
        var importedByPlaidID = fetchImportedIndex()
        let rules = fetchRules()
        let activeGoals = fetchActiveGoals()

        var hasMore = true
        while hasMore {
            let response: PlaidSyncResponseBody
            do {
                response = try await syncPage(accessToken: accessToken, cursor: requestCursor, environment: environment)
            } catch {
                presentedError = PlaidErrorClassifier.classify(.exchangeError(error))
                break
            }

            let pageResult = processPage(
                response,
                manualTransactions: &manualTransactions,
                importedByPlaidID: &importedByPlaidID,
                rules: rules,
                activeGoals: activeGoals
            )
            summary.added += pageResult.summary.added
            summary.modified += pageResult.summary.modified
            summary.removed += pageResult.summary.removed
            summary.queuedForMerge += pageResult.summary.queuedForMerge

            if pageResult.allHandled {
                cursorStore.setCursor(response.next_cursor, for: environment)
                requestCursor = response.next_cursor
                hasMore = response.has_more
            } else {
                hasMore = false
            }
        }

        lastImportSummary = summary
    }

    /// Resolves the current `pendingMergeDecision` (the queue's head). Synchronous — no
    /// network call needed, only local persistence — so the next pending decision (if
    /// any) is picked up reactively by the view's binding to `pendingMergeDecision`.
    func resolveMergeDecision(_ choice: MergeChoice) {
        guard !mergeQueue.isEmpty else { return }
        let decision = mergeQueue.removeFirst()

        switch choice {
        case .merge:
            applyMergeDecision(decision)
        case .keepBoth:
            applyKeepBothDecision(decision)
        }
    }

    // MARK: - Page processing

    private struct PageResult {
        var summary = ImportSummary()
        var allHandled = true
    }

    private func processPage(
        _ response: PlaidSyncResponseBody,
        manualTransactions: inout [SpendTransaction],
        importedByPlaidID: inout [String: SpendTransaction],
        rules: [MerchantRule],
        activeGoals: [SavingsGoal]
    ) -> PageResult {
        var result = PageResult()

        for raw in response.added {
            guard let mapped = PlaidTransactionMapper.map(raw) else { continue }

            if let match = TransactionDedupMatcher.findMatch(for: mapped, existingManualTransactions: manualTransactions) {
                mergeQueue.append(PendingMergeDecision(id: mapped.plaidTransactionID, manualTransaction: match, incoming: mapped))
                // Remove the matched manual transaction from further matching this run —
                // a manual entry should be offered for merge against at most one
                // incoming transaction per import.
                manualTransactions.removeAll { $0.persistentModelID == match.persistentModelID }
                result.summary.queuedForMerge += 1
                continue
            }

            let newTransaction = buildNewImportedTransaction(from: mapped, rules: rules, activeGoals: activeGoals)
            let failureMessage = PersistenceSaveHelper.saveOrRollback(
                modelContext: modelContext,
                mutate: { modelContext.insert(newTransaction) },
                rollback: { modelContext.delete(newTransaction) },
                logger: logger
            )
            if let failureMessage {
                logger.error("Failed to save imported transaction \(mapped.plaidTransactionID, privacy: .public): \(failureMessage, privacy: .public)")
                result.allHandled = false
            } else {
                importedByPlaidID[mapped.plaidTransactionID] = newTransaction
                result.summary.added += 1
            }
        }

        for raw in response.modified {
            guard let mapped = PlaidTransactionMapper.map(raw) else { continue }
            guard let existing = importedByPlaidID[mapped.plaidTransactionID] else {
                // Nothing locally to update (e.g. it was a credit we never imported, or
                // predates this app's import history) — no-op, still handled.
                continue
            }

            let original = SnapshotForRollback(existing)
            let failureMessage = PersistenceSaveHelper.saveOrRollback(
                modelContext: modelContext,
                mutate: { Self.applyModified(existing, mapped: mapped, rules: rules) },
                rollback: { original.restore(to: existing) },
                logger: logger
            )
            if let failureMessage {
                logger.error("Failed to apply modified transaction \(mapped.plaidTransactionID, privacy: .public): \(failureMessage, privacy: .public)")
                result.allHandled = false
            } else {
                result.summary.modified += 1
            }
        }

        for raw in response.removed {
            guard let existing = importedByPlaidID[raw.transaction_id] else {
                continue
            }

            let failureMessage: String?
            if existing.wasMergedFromManual {
                let original = SnapshotForRollback(existing)
                failureMessage = PersistenceSaveHelper.saveOrRollback(
                    modelContext: modelContext,
                    mutate: {
                        existing.entryMethod = .manual
                        existing.plaidTransactionID = nil
                        existing.wasMergedFromManual = false
                    },
                    rollback: { original.restore(to: existing) },
                    logger: logger
                )
            } else {
                failureMessage = PersistenceSaveHelper.deleteWithRollback(existing, modelContext: modelContext, logger: logger)
            }

            if let failureMessage {
                logger.error("Failed to apply removed transaction \(raw.transaction_id, privacy: .public): \(failureMessage, privacy: .public)")
                result.allHandled = false
            } else {
                importedByPlaidID.removeValue(forKey: raw.transaction_id)
                result.summary.removed += 1
            }
        }

        return result
    }

    /// Captures the fields `applyModified`/the `removed`-revert path mutate, so a failed
    /// save can be rolled back to exactly what was there before — `SpendTransaction` has
    /// no `.nullify`-relationship rollback caveat here (see `SchemaV4`'s migration doc
    /// comment), so a plain field snapshot/restore is sufficient.
    private struct SnapshotForRollback {
        let amount: Decimal
        let date: Date
        let merchantName: String
        let type: TransactionType
        let entryMethod: EntryMethod
        let plaidTransactionID: String?
        let wasMergedFromManual: Bool

        init(_ transaction: SpendTransaction) {
            amount = transaction.amount
            date = transaction.date
            merchantName = transaction.merchantName
            type = transaction.type
            entryMethod = transaction.entryMethod
            plaidTransactionID = transaction.plaidTransactionID
            wasMergedFromManual = transaction.wasMergedFromManual
        }

        func restore(to transaction: SpendTransaction) {
            transaction.amount = amount
            transaction.date = date
            transaction.merchantName = merchantName
            transaction.type = type
            transaction.entryMethod = entryMethod
            transaction.plaidTransactionID = plaidTransactionID
            transaction.wasMergedFromManual = wasMergedFromManual
        }
    }

    /// `modified` upsert: Plaid wins on amount/date/merchantName (same as the Merge
    /// resolution path); `type` is re-derived via `MerchantMatcher` only when the
    /// transaction hasn't been manually overridden — an explicit user choice must never
    /// be silently clobbered by an upstream Plaid edit. `savingsGoal` is left untouched.
    private static func applyModified(_ existing: SpendTransaction, mapped: MappedPlaidTransaction, rules: [MerchantRule]) {
        existing.amount = mapped.amount
        existing.date = mapped.date
        existing.merchantName = mapped.merchantName
        if !existing.isManualOverride {
            existing.type = MerchantMatcher.match(rules: rules, merchantName: mapped.merchantName) ?? .variable
        }
    }

    // MARK: - Merge-decision resolution

    private func applyMergeDecision(_ decision: PendingMergeDecision) {
        let original = SnapshotForRollback(decision.manualTransaction)
        let failureMessage = PersistenceSaveHelper.saveOrRollback(
            modelContext: modelContext,
            mutate: { TransactionDedupMatcher.applyMerge(to: decision.manualTransaction, incoming: decision.incoming) },
            rollback: { original.restore(to: decision.manualTransaction) },
            logger: logger
        )
        if let failureMessage {
            logger.error("Failed to apply merge for \(decision.incoming.plaidTransactionID, privacy: .public): \(failureMessage, privacy: .public)")
        }
    }

    private func applyKeepBothDecision(_ decision: PendingMergeDecision) {
        let rules = fetchRules()
        let activeGoals = fetchActiveGoals()
        let newTransaction = buildNewImportedTransaction(from: decision.incoming, rules: rules, activeGoals: activeGoals)
        let failureMessage = PersistenceSaveHelper.saveOrRollback(
            modelContext: modelContext,
            mutate: { modelContext.insert(newTransaction) },
            rollback: { modelContext.delete(newTransaction) },
            logger: logger
        )
        if let failureMessage {
            logger.error("Failed to save keep-both transaction \(decision.incoming.plaidTransactionID, privacy: .public): \(failureMessage, privacy: .public)")
        }
    }

    // MARK: - Construction

    /// Shared by the no-dedup-match `added` path and the "Keep both" resolution path —
    /// both build an identical new `SpendTransaction` from a `MappedPlaidTransaction`,
    /// so this is the one place that construction happens (per STANDARDS §3, no
    /// near-duplicate constructors).
    private func buildNewImportedTransaction(
        from mapped: MappedPlaidTransaction,
        rules: [MerchantRule],
        activeGoals: [SavingsGoal]
    ) -> SpendTransaction {
        let type = MerchantMatcher.match(rules: rules, merchantName: mapped.merchantName) ?? .variable
        let goal: SavingsGoal?
        switch TransactionEntryValidator.goalAttributionRequirement(activeGoals: activeGoals) {
        case .autoSelect(let onlyGoal):
            goal = onlyGoal
        case .noActiveGoals, .explicitChoiceRequired:
            goal = nil
        }

        return SpendTransaction(
            amount: mapped.amount,
            date: mapped.date,
            merchantName: mapped.merchantName,
            type: type,
            entryMethod: .imported,
            plaidTransactionID: mapped.plaidTransactionID,
            isManualOverride: false,
            savingsGoal: goal
        )
    }

    // MARK: - Fetches (this service owns its own reads — see type doc comment)

    /// Fetches every `SpendTransaction` and filters in Swift rather than via a
    /// `#Predicate` on `entryMethod`/`plaidTransactionID` — this app's transaction
    /// volume is personal-scale, and every existing fetch site (`MerchantRuleEntryView`
    /// being the sole `#Predicate` precedent) only ever predicates on plain `String`
    /// properties, not this model's `Codable` enum or optional-comparison fields, so
    /// filtering in-memory avoids relying on unproven predicate-macro behavior for
    /// those shapes.
    private func fetchAllTransactions() -> [SpendTransaction] {
        (try? modelContext.fetch(FetchDescriptor<SpendTransaction>())) ?? []
    }

    private func fetchManualTransactions() -> [SpendTransaction] {
        fetchAllTransactions().filter { $0.entryMethod == .manual }
    }

    private func fetchImportedIndex() -> [String: SpendTransaction] {
        var index: [String: SpendTransaction] = [:]
        for transaction in fetchAllTransactions() {
            if let id = transaction.plaidTransactionID {
                index[id] = transaction
            }
        }
        return index
    }

    private func fetchRules() -> [MerchantRule] {
        (try? modelContext.fetch(FetchDescriptor<MerchantRule>())) ?? []
    }

    private func fetchActiveGoals() -> [SavingsGoal] {
        let goals = (try? modelContext.fetch(FetchDescriptor<SavingsGoal>())) ?? []
        return TodayScreenCalculator.activeGoals(goals, referenceDate: .now)
    }

    // MARK: - Plaid REST call (direct from device, environment-aware)

    /// Duplicates `PlaidServiceLive`'s small `post(_:body:)` networking helper (build
    /// request, POST, decode, map non-2xx to `URLError`) rather than extracting a shared
    /// client — this is boilerplate glue, not the business-logic duplication STANDARDS §3
    /// is aimed at, and there are only two Plaid REST call sites in the app today (rule
    /// of three). Revisit extraction if a third shows up (e.g. adq.6.5's relink flow).
    private func syncPage(accessToken: String, cursor: String?, environment: PlaidEnvironment) async throws -> PlaidSyncResponseBody {
        let body = PlaidSyncRequestBody(
            client_id: PlaidCredentials.clientID,
            secret: PlaidCredentials.secret(
                for: environment,
                sandboxSecret: PlaidCredentials.sandboxSecret,
                productionSecret: PlaidCredentials.productionSecret
            ),
            access_token: accessToken,
            cursor: cursor,
            count: 100
        )
        return try await post("/transactions/sync", body: body, baseURL: environment.baseURL)
    }

    private func post<Body: Encodable, Response: Decodable>(_ path: String, body: Body, baseURL: URL) async throws -> Response {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}
