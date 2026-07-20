import Foundation
import Observation
import SwiftData
import SwiftUI
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

/// Plaid's documented shape for a REST call's JSON error body (`/transactions/sync`
/// included) — `error_type`/`error_code` are the two fields `PlaidErrorClassifier`'s
/// `.itemError` case matches against (e.g. `"ITEM_ERROR"`/`"ITEM_LOGIN_REQUIRED"`).
/// Decoded by `post(_:body:baseURL:)` on a non-2xx response (reservoir-adq.6.5) — see
/// that method's doc comment for why decoding the body on failure wasn't happening before.
struct PlaidAPIErrorBody: Decodable {
    let error_type: String?
    let error_code: String?
}

/// Thrown by `post(_:body:baseURL:)` when a non-2xx response's body decodes as a
/// recognizable Plaid error (`error_type`/`error_code` present) — carries those two
/// fields through to `runImport()`'s `catch`, which routes it to
/// `PlaidErrorClassifier.classify(.itemError(errorType:errorCode:))` instead of the
/// generic `.exchangeError(_:)` path every other failure still takes.
struct PlaidAPIError: Error {
    let errorType: String?
    let errorCode: String?
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
    /// Mirrors the linked item's `needsAttention` flag (reservoir-adq.6.5) — `true`
    /// whenever the most recent import attempt classified as `.itemLoginRequired`. Synced
    /// from `linkedItemStore` at `init` and at the start of every `runImport()` (alongside
    /// `hydrateMergeQueue()`), so a fresh instance picks up whatever the last session (or a
    /// completed relink) left behind. Also refreshable on demand via
    /// `refreshNeedsAttention()` — `SettingsView` calls that right after a successful
    /// relink or unlink so the Today-screen badge (bound to this property) clears
    /// immediately rather than waiting for the next import.
    private(set) var needsAttention: Bool
    /// The raw underlying error behind `presentedError`, kept alongside the coarse
    /// category (rather than discarded at classification time) so the UI can offer an
    /// optional "technical details" reveal for a technically-inclined user, without
    /// changing the friendly, coarse-category text shown by default. `nil` whenever
    /// `presentedError` is `nil`.
    private(set) var presentedErrorDetail: String?
    private(set) var lastImportSummary: ImportSummary?
    /// In-memory mirror of the `PendingTransactionMerge` rows in `modelContext` —
    /// durable persistence (see `SchemaV5`'s doc comment) is what actually survives app
    /// relaunch; this array is re-hydrated from that store at `init` and at the start of
    /// every `runImport()` call via `hydrateMergeQueue()`, and kept in sync with it by
    /// every mutation below (`processPage`'s queueing, `resolveMergeDecision`'s
    /// deletion). Never mutated independent of the persisted store.
    private(set) var mergeQueue: [PendingMergeDecision] = []
    var pendingMergeDecision: PendingMergeDecision? { mergeQueue.first }

    /// Tracks whether a genuine `.background` phase has been observed since the last
    /// import-triggering `.active` transition — see `handleScenePhaseTransition`'s doc
    /// comment for why this can't just compare an `(oldPhase, newPhase)` pair directly.
    private var hasBackgroundedSinceActive = false

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
    private let linkedItemStore: LinkedItemStoring
    private let logger: Logger

    init(
        modelContext: ModelContext,
        keychain: KeychainServicing = KeychainService(),
        urlSession: URLSession = .shared,
        environmentStore: PlaidEnvironmentStoring = PlaidEnvironmentStore(),
        cursorStore: PlaidSyncCursorStoring = PlaidSyncCursorStore(),
        linkedItemStore: LinkedItemStoring = LinkedItemStore(),
        logger: Logger = Logger(subsystem: "com.reservoir.app", category: "TransactionImportService")
    ) {
        self.modelContext = modelContext
        self.keychain = keychain
        self.urlSession = urlSession
        self.environmentStore = environmentStore
        self.cursorStore = cursorStore
        self.linkedItemStore = linkedItemStore
        self.logger = logger
        self.needsAttention = linkedItemStore.load()?.needsAttention ?? false
        hydrateMergeQueue()
    }

    /// Re-reads `needsAttention` from `linkedItemStore` on demand — see the property's
    /// doc comment for why this exists alongside the automatic sync at the start of every
    /// `runImport()`.
    func refreshNeedsAttention() {
        needsAttention = linkedItemStore.load()?.needsAttention ?? false
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
    /// Testable seam for adq.6.4's app-foreground trigger. SwiftUI fires a separate
    /// `.onChange(of: scenePhase)` callback for each discrete phase change, not one
    /// coalesced call spanning a multi-step transition — a real return from background
    /// arrives as two calls, `(.background, .inactive)` then `(.inactive, .active)`, so
    /// comparing a single call's `(oldPhase, newPhase)` pair against `(.background,
    /// .active)` can never match (that was this method's original, broken shape).
    /// Instead this tracks `hasBackgroundedSinceActive` across calls: cold launch's
    /// `.inactive → .active` sequence never passes through `.background` first, so the
    /// flag stays unset and correctly excludes it, while a genuine backgrounding sets it
    /// so the next `.active` transition (regardless of how many intermediate `.inactive`
    /// calls preceded it) triggers exactly one import. Unit tests drive this by calling
    /// the method once per phase in the same sequence a real device would produce, rather
    /// than needing an XCUITest to actually background/foreground the device.
    ///
    /// The flag is only consumed once `runImport()` is actually about to run, not merely
    /// attempted: if a foreground-return lands while another import (pull-to-refresh, the
    /// debug button, or an earlier scene-phase transition) is already in flight,
    /// `runImport()`'s own `guard !isImporting` would otherwise silently no-op while this
    /// method had already reset the flag — losing that foreground-triggered sync until an
    /// entire extra background/foreground round-trip. Checking `isImporting` here first
    /// leaves the flag armed so the very next `.active` transition retries instead (code
    /// review finding: a prior version reset the flag unconditionally before calling
    /// `runImport()`).
    func handleScenePhaseTransition(to newPhase: ScenePhase) async {
        switch newPhase {
        case .background:
            hasBackgroundedSinceActive = true
        case .active:
            guard hasBackgroundedSinceActive, !isImporting else { return }
            hasBackgroundedSinceActive = false
            await runImport()
        default:
            break
        }
    }

    func runImport() async {
        guard !isImporting else { return }
        isImporting = true
        defer { isImporting = false }

        presentedError = nil
        presentedErrorDetail = nil

        guard let accessToken = try? await keychain.read(for: PlaidKeychainKey.accessToken) else {
            // No linked item yet, or the keychain read failed — nothing to import,
            // not an error surfaced to the user (background operation). Still resync
            // needsAttention before returning (code review finding, reservoir-adq.6.5):
            // an environment switch clears both the Keychain token and the persisted
            // linked item via `PlaidEnvironmentStore.onChange`, but without this the
            // in-memory flag from a stale linked item would stay stuck `true` forever,
            // since every earlier return path in this method skipped the sync below.
            refreshNeedsAttention()
            return
        }

        let environment = environmentStore.current
        var requestCursor = cursorStore.cursor(for: environment)
        var summary = ImportSummary()

        // Re-hydrate from the persisted store before fetching candidates: another
        // `TransactionImportService` instance (a prior app session, most likely) may
        // have queued decisions still unresolved. Excluding their manual transactions
        // from this run's candidate pool is what stops a second, independent sync from
        // matching the same manual row into a duplicate pending decision (review
        // finding 5).
        hydrateMergeQueue()
        refreshNeedsAttention()
        var manualTransactions = fetchManualTransactions()
        let alreadyQueuedManualIDs = Set(mergeQueue.map(\.manualTransaction.persistentModelID))
        manualTransactions.removeAll { alreadyQueuedManualIDs.contains($0.persistentModelID) }

        var importedByPlaidID = fetchImportedIndex()
        let rules = fetchRules()
        let activeGoals = fetchActiveGoals()

        var hasMore = true
        while hasMore {
            let response: PlaidSyncResponseBody
            do {
                response = try await syncPage(accessToken: accessToken, cursor: requestCursor, environment: environment)
            } catch {
                // A decoded Plaid item-level error body (reservoir-adq.6.5) is classified
                // distinctly from every other failure here — a genuine ITEM_LOGIN_REQUIRED
                // sets the persistent needsAttention flag; a plain network/transport error
                // or an unrecognized error shape (still `.exchangeError`, same as before
                // this story) must NOT, so a flaky connection during a foreground refresh
                // doesn't falsely trip the "needs attention" UI (see this story's UX
                // section / Out of scope).
                if let apiError = error as? PlaidAPIError {
                    let category = PlaidErrorClassifier.classify(.itemError(errorType: apiError.errorType, errorCode: apiError.errorCode))
                    presentedError = category
                    if category == .itemLoginRequired {
                        needsAttention = true
                        linkedItemStore.setNeedsAttention(true)
                    }
                } else {
                    presentedError = PlaidErrorClassifier.classify(.exchangeError(error))
                }
                presentedErrorDetail = String(describing: error)
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
                // Persist the decision (review findings 2+5) so it survives process
                // death and can't be independently re-queued by a later sync run — see
                // `SchemaV5`'s doc comment. Only append to the in-memory `mergeQueue`
                // (and remove `match` from this run's remaining candidates) once the
                // persisted row actually saved; a save failure here is handled the same
                // way a save failure elsewhere in this loop is — logged, counted as
                // unhandled so the page's cursor doesn't advance, retried next sync.
                let record = PendingTransactionMerge(
                    plaidTransactionID: mapped.plaidTransactionID,
                    incomingAmount: mapped.amount,
                    incomingDate: mapped.date,
                    incomingMerchantName: mapped.merchantName,
                    manualTransaction: match
                )
                let failureMessage = PersistenceSaveHelper.saveOrRollback(
                    modelContext: modelContext,
                    mutate: { modelContext.insert(record) },
                    rollback: { modelContext.delete(record) },
                    logger: logger
                )
                if let failureMessage {
                    logger.error("Failed to queue merge decision for \(mapped.plaidTransactionID, privacy: .public): \(failureMessage, privacy: .public)")
                    result.allHandled = false
                } else {
                    mergeQueue.append(PendingMergeDecision(id: mapped.plaidTransactionID, manualTransaction: match, incoming: mapped))
                    // Remove the matched manual transaction from further matching this
                    // run — a manual entry should be offered for merge against at most
                    // one incoming transaction per import.
                    manualTransactions.removeAll { $0.persistentModelID == match.persistentModelID }
                    result.summary.queuedForMerge += 1
                }
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
            // A queued-not-saved decision is a frozen snapshot that was never added to
            // `importedByPlaidID`, so the checks below it would silently miss a later
            // `modified` event for the same `transaction_id` (review finding 3) — check
            // `mergeQueue` first. A non-positive new amount (e.g. reclassified as a
            // refund) means this is no longer a live duplicate to resolve — the pending
            // decision is dropped rather than left pointing at stale/invalid Plaid data
            // (UX call: the merge prompt simply disappears, same as if it had never
            // matched; the manual transaction is left untouched and becomes eligible
            // for matching again on a future sync). Otherwise, the queued snapshot's
            // data is refreshed so a later "Merge" resolution uses current data.
            if let queuedIndex = mergeQueue.firstIndex(where: { $0.id == raw.transaction_id }) {
                if let mapped = PlaidTransactionMapper.map(raw) {
                    if updateQueuedDecision(at: queuedIndex, with: mapped) {
                        result.summary.modified += 1
                    } else {
                        result.allHandled = false
                    }
                } else {
                    if removeQueuedDecision(at: queuedIndex) {
                        result.summary.removed += 1
                    } else {
                        result.allHandled = false
                    }
                }
                continue
            }

            // A `modified` event whose new amount is non-positive (review finding 4)
            // maps to `nil` via `PlaidTransactionMapper.map` before `raw.transaction_id`
            // is ever looked up — checking `mapped == nil` alone can't distinguish that
            // from a malformed date, so this checks `raw.amount` directly and, only for
            // the non-positive-amount case, applies the same delete-or-revert handling
            // as a genuine `removed` event: the existing row's stale (pre-refund) amount
            // must not be left in place forever.
            if raw.amount <= 0 {
                if let existing = importedByPlaidID[raw.transaction_id] {
                    let failureMessage = deleteOrRevertExisting(existing)
                    if let failureMessage {
                        logger.error("Failed to apply non-positive modified transaction \(raw.transaction_id, privacy: .public): \(failureMessage, privacy: .public)")
                        result.allHandled = false
                    } else {
                        importedByPlaidID.removeValue(forKey: raw.transaction_id)
                        result.summary.removed += 1
                    }
                }
                continue
            }

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
            // Same reasoning as the `modified` loop above (review finding 3): a
            // queued-not-saved decision is invisible to `importedByPlaidID`, so a
            // `removed` event for it must be checked against `mergeQueue` directly, or
            // the decision would be left pointing at a since-voided Plaid transaction.
            if let queuedIndex = mergeQueue.firstIndex(where: { $0.id == raw.transaction_id }) {
                if removeQueuedDecision(at: queuedIndex) {
                    result.summary.removed += 1
                } else {
                    result.allHandled = false
                }
                continue
            }

            guard let existing = importedByPlaidID[raw.transaction_id] else {
                continue
            }

            let failureMessage = deleteOrRevertExisting(existing)
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

    /// Shared by the `removed` loop and the `modified` loop's non-positive-amount path
    /// (review finding 4) — both need to either hard-delete a pure import or revert a
    /// merge-derived row back to `.manual`, identically (STANDARDS §3, no near-duplicate
    /// logic).
    private func deleteOrRevertExisting(_ existing: SpendTransaction) -> String? {
        if existing.wasMergedFromManual {
            let original = SnapshotForRollback(existing)
            return PersistenceSaveHelper.saveOrRollback(
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
            return PersistenceSaveHelper.deleteWithRollback(existing, modelContext: modelContext, logger: logger)
        }
    }

    /// Refreshes a still-queued decision's persisted snapshot with newer Plaid data
    /// (review finding 3). Returns `false` on a persistence failure (logged; caller
    /// marks the page unhandled so it's retried), `true` on success — mirrors every
    /// other `Bool`-via-`failureMessage` handling pattern in this file.
    private func updateQueuedDecision(at index: Int, with mapped: MappedPlaidTransaction) -> Bool {
        let decision = mergeQueue[index]
        guard let record = fetchPendingMerge(plaidTransactionID: decision.id) else {
            // Persisted row is missing (shouldn't happen outside test doubles/manual DB
            // surgery) — nothing durable to update; drop the stale in-memory entry too.
            mergeQueue.remove(at: index)
            return true
        }

        let originalAmount = record.incomingAmount
        let originalDate = record.incomingDate
        let originalMerchantName = record.incomingMerchantName
        let failureMessage = PersistenceSaveHelper.saveOrRollback(
            modelContext: modelContext,
            mutate: {
                record.incomingAmount = mapped.amount
                record.incomingDate = mapped.date
                record.incomingMerchantName = mapped.merchantName
            },
            rollback: {
                record.incomingAmount = originalAmount
                record.incomingDate = originalDate
                record.incomingMerchantName = originalMerchantName
            },
            logger: logger
        )
        if let failureMessage {
            logger.error("Failed to update queued merge decision \(decision.id, privacy: .public): \(failureMessage, privacy: .public)")
            return false
        }
        mergeQueue[index] = PendingMergeDecision(id: decision.id, manualTransaction: decision.manualTransaction, incoming: mapped)
        return true
    }

    /// Deletes a still-queued decision's persisted row and its in-memory mirror (review
    /// finding 3) — used when a `modified` (non-positive amount) or `removed` event
    /// reports that the incoming side of a pending decision is no longer live. Returns
    /// `false` on a persistence failure (logged; caller marks the page unhandled).
    private func removeQueuedDecision(at index: Int) -> Bool {
        let decision = mergeQueue[index]
        guard let record = fetchPendingMerge(plaidTransactionID: decision.id) else {
            mergeQueue.remove(at: index)
            return true
        }

        let failureMessage = PersistenceSaveHelper.deleteWithRollback(record, modelContext: modelContext, logger: logger)
        if let failureMessage {
            logger.error("Failed to clear queued merge decision \(decision.id, privacy: .public): \(failureMessage, privacy: .public)")
            return false
        }
        mergeQueue.remove(at: index)
        return true
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

    /// Both resolution paths below fold the persisted `PendingTransactionMerge` row's
    /// deletion into the same `saveOrRollback` transaction as the rest of the
    /// resolution's mutation — not a separate save afterward — so a failure can't leave
    /// the manual transaction merged/a new row inserted while the persisted decision
    /// record is still sitting there (which would resurrect the resolved decision the
    /// next time `hydrateMergeQueue()` runs). `resolveMergeDecision` has already removed
    /// `decision` from the in-memory `mergeQueue` before either of these run; on failure
    /// the persisted row is rolled back (re-inserted), so it's picked back up by the
    /// next `hydrateMergeQueue()` call rather than silently lost.
    private func applyMergeDecision(_ decision: PendingMergeDecision) {
        let original = SnapshotForRollback(decision.manualTransaction)
        let record = fetchPendingMerge(plaidTransactionID: decision.id)
        let failureMessage = PersistenceSaveHelper.saveOrRollback(
            modelContext: modelContext,
            mutate: {
                TransactionDedupMatcher.applyMerge(to: decision.manualTransaction, incoming: decision.incoming)
                if let record { modelContext.delete(record) }
            },
            rollback: {
                original.restore(to: decision.manualTransaction)
                if let record { modelContext.insert(record) }
            },
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
        let record = fetchPendingMerge(plaidTransactionID: decision.id)
        let failureMessage = PersistenceSaveHelper.saveOrRollback(
            modelContext: modelContext,
            mutate: {
                modelContext.insert(newTransaction)
                if let record { modelContext.delete(record) }
            },
            rollback: {
                modelContext.delete(newTransaction)
                if let record { modelContext.insert(record) }
            },
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

    // MARK: - Merge-queue persistence (review findings 2+5 — see `SchemaV5`'s doc comment)

    /// Rebuilds `mergeQueue` from every persisted `PendingTransactionMerge` row. Called
    /// at `init` (so a relaunch immediately surfaces any decision left unresolved from a
    /// prior session, without waiting on a network call) and at the start of every
    /// `runImport()` (so a second, independent sync run sees decisions queued since this
    /// instance was constructed). A row whose `manualTransaction` relationship has gone
    /// nil (the referenced `SpendTransaction` was deleted out from under it — not
    /// expected in normal flow, no UI deletes a manual transaction with an unresolved
    /// merge prompt) is dropped as orphaned rather than surfaced as an unresolvable
    /// decision.
    private func hydrateMergeQueue() {
        let persisted = (try? modelContext.fetch(FetchDescriptor<PendingTransactionMerge>())) ?? []
        mergeQueue = persisted.compactMap { record in
            guard let manual = record.manualTransaction else { return nil }
            let incoming = MappedPlaidTransaction(
                plaidTransactionID: record.plaidTransactionID,
                amount: record.incomingAmount,
                date: record.incomingDate,
                merchantName: record.incomingMerchantName
            )
            return PendingMergeDecision(id: record.plaidTransactionID, manualTransaction: manual, incoming: incoming)
        }
    }

    private func fetchPendingMerge(plaidTransactionID: String) -> PendingTransactionMerge? {
        var descriptor = FetchDescriptor<PendingTransactionMerge>(
            predicate: #Predicate { $0.plaidTransactionID == plaidTransactionID }
        )
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first
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
    /// of three — a third now exists, `PlaidServiceLive.createRelinkToken`, but that one
    /// doesn't need this method's non-2xx body-decoding behavior below, so extraction
    /// still isn't a clear win; revisit if a fourth call site needs the same decoding).
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

    /// **Behavior change (reservoir-adq.6.5)**: on a non-2xx response, this now attempts
    /// to decode the body as `PlaidAPIErrorBody` before falling back to the old
    /// `URLError(.badServerResponse)`. Previously the body was discarded outright on any
    /// non-2xx status, which made `ITEM_LOGIN_REQUIRED` (carried in that body)
    /// unreachable — `runImport()`'s catch block had no way to distinguish a genuine item
    /// auth error from a transient/network one. Every other non-2xx failure path is
    /// unchanged: a body that fails to decode as `PlaidAPIErrorBody`, or one that decodes
    /// but has both `error_type`/`error_code` nil (not a recognizable Plaid error shape —
    /// an HTML error page, an empty body, a malformed JSON blob), still throws
    /// `URLError(.badServerResponse)` exactly as before, which `PlaidErrorClassifier`
    /// still classifies as `.plaidSide` via the `.exchangeError(_:)` path in `runImport()`.
    /// Only a body that decodes with at least one of those two fields present takes the
    /// new `PlaidAPIError` path.
    private func post<Body: Encodable, Response: Decodable>(_ path: String, body: Body, baseURL: URL) async throws -> Response {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            if let errorBody = try? JSONDecoder().decode(PlaidAPIErrorBody.self, from: data),
               errorBody.error_type != nil || errorBody.error_code != nil {
                throw PlaidAPIError(errorType: errorBody.error_type, errorCode: errorBody.error_code)
            }
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}
