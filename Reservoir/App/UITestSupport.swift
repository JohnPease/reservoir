import Foundation
import SwiftData

#if DEBUG
/// Named, deterministic SwiftData fixtures the app seeds into an in-memory store when
/// launched under XCUITest with `UITEST_SCENARIO` set — see `ReservoirApp`. Debug-only:
/// this scaffolding never ships in a Release/sideload build.
enum UITestScenario: String {
    /// No goals at all — the Today screen's "no active goal" empty state.
    case emptyGoal
    /// One active goal with a mix of variable and fixed transactions — the Today
    /// screen's normal state.
    case normal
    /// One goal whose `targetDate` has already passed and hasn't been dismissed yet —
    /// the Today screen's completion banner.
    case completedGoalBanner
    /// Same as `completedGoalBanner`, plus an orphaned (no `savingsGoal`) transaction
    /// dated today — regression coverage for review finding 2: today's spend must still
    /// be visible even though there's no active goal, and the empty-state prompt must
    /// not render underneath the completion banner.
    case completedGoalBannerWithOrphanedSpend
    /// A goal whose `targetDate` has already passed and hasn't been dismissed yet, but
    /// whose cumulative carry-forward balance is negative through `targetDate` — the
    /// "not met" completion banner variant (reservoir-4za).
    case completedGoalBannerNotMet
    /// One active goal (no spend at all, so Pace reads "on pace" and Simulation reads
    /// "ahead of target") plus one completed-undismissed goal simultaneously — the
    /// Goals tab's (adq.5) "both sections render together" state.
    case goalsScreenMixed

    /// One active goal plus three transactions spanning today/yesterday, a mix of
    /// variable/fixed and attributed/unattributed — the Transactions tab's (adq.3) list
    /// rendering, day-grouping, filter, edit, and delete flows.
    case transactionsList
    /// No goals and no transactions at all — exercises the Transactions tab's own "+"
    /// entry point's zero-active-goals goal-attribution default (adq.3, 2026-07-12
    /// clarification), which is reachable here unlike Today's "Add transaction" (Today
    /// hides that button entirely with zero goals).
    case transactionsZeroGoals
    /// Two existing `MerchantRule`s ("Starbucks" -> variable, "Amazon" -> fixed) and no
    /// transactions — the Merchant Rules list's edit/delete/duplicate-name-rejection
    /// flows (adq.3).
    case merchantRulesManage
    /// No existing `MerchantRule`s, plus two "Uber" transactions dated today: one
    /// ordinary (`isManualOverride == false`) and one the user has manually overridden
    /// (`isManualOverride == true`), both currently `variable`. Creating/editing a rule
    /// for "Uber" -> fixed should retag only the non-overridden one — adq.3's
    /// retroactive-retag AC and the `isManualOverride` protection check together.
    case merchantRulesRetag

    /// One manual `SpendTransaction` ("Coffee Shop", $12.50, dated `todayForImportTests`)
    /// that exactly matches the scripted Plaid transaction
    /// `PlaidImportMergePromptURLProtocol` returns from `/transactions/sync` — backs
    /// `TransactionImportUITests` (adq.6.3's mandated merge-prompt end-to-end coverage).
    case transactionImportMergePrompt

    static var current: UITestScenario? {
        ProcessInfo.processInfo.environment["UITEST_SCENARIO"].flatMap(UITestScenario.init(rawValue:))
    }

    /// A stubbed `URLProtocol` that fails every request with a non-2xx HTTP
    /// response, regardless of what's actually configured in
    /// `Config/Plaid.xcconfig`. Backs `UITestScenario.plaidURLSession` so
    /// `PlaidDebugLinkUITests`' error-classification test is deterministic —
    /// it must not depend on whether the developer's local xcconfig happens
    /// to hold valid or invalid Sandbox credentials (see reservoir-z0o: the
    /// old custom-scheme redirect_uri used to make that test pass "by
    /// accident" by getting rejected outright; the https universal-link
    /// redirect_uri Plaid now requires no longer does that when credentials
    /// are valid).
    private final class PlaidForcedFailureURLProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            // Any non-2xx status makes PlaidServiceLive.post(_:body:) throw
            // URLError(.badServerResponse), which PlaidErrorClassifier maps
            // to .plaidSide — the same real, non-network failure path a
            // genuine Plaid-side rejection takes, just without depending on
            // Plaid's actual Sandbox API or real credentials.
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://sandbox.plaid.com")!,
                statusCode: 400,
                httpVersion: nil,
                headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    /// Fixture constants shared between `.transactionImportMergePrompt`'s seeded manual
    /// `SpendTransaction` (see `seed(into:)` below) and
    /// `PlaidImportMergePromptURLProtocol`'s scripted `/transactions/sync` response —
    /// both need to agree exactly (amount, merchant, calendar day) for
    /// `TransactionDedupMatcher.findMatch` to actually fire during
    /// `TransactionImportUITests`.
    static let transactionImportMergePromptMerchantName = "Coffee Shop"
    static let transactionImportMergePromptAmount: Decimal = 12.50
    static let transactionImportMergePromptPlaidTransactionID = "uitest-plaid-merge-1"

    /// `yyyy-MM-dd` (UTC), matching `PlaidTransactionMapper`'s expected wire format —
    /// used both to build the scripted `/transactions/sync` response's `date` field and
    /// to parse the exact same `Date` back for the seeded manual transaction, so the two
    /// land on the same calendar day regardless of the device's local time zone.
    private static var todayDateString: String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: .now)
    }

    /// `todayDateString`, parsed back to a `Date` via `PlaidTransactionMapper`'s own
    /// `localDate(from:calendar:)` — the same local-calendar-midnight parse the
    /// production import path uses for the scripted transaction's date — rather than a
    /// second, independent `DateFormatter` parse. Re-implementing the parse here
    /// previously drifted from the mapper (this parsed UTC-pinned midnight, the mapper
    /// parses device-local midnight), which on a UTC-behind device put the seeded
    /// manual transaction and the incoming scripted transaction on different calendar
    /// days, so `TransactionDedupMatcher.findMatch` never matched them and the merge
    /// prompt never appeared. Calling the mapper's own helper makes that drift
    /// structurally impossible.
    static var todayForImportTests: Date {
        PlaidTransactionMapper.localDate(from: todayDateString, calendar: .current)!
    }

    /// A stubbed `URLProtocol` answering `/transactions/sync` with one scripted `added`
    /// transaction that exactly matches `.transactionImportMergePrompt`'s seeded manual
    /// entry — backs `TransactionImportUITests`, letting it drive the real import
    /// pipeline (`TransactionImportService.runImport()`, `TransactionDedupMatcher`, the
    /// merge prompt) end to end without depending on Plaid's actual Sandbox API or local
    /// credentials, same reasoning as `PlaidForcedFailureURLProtocol` above.
    private final class PlaidImportMergePromptURLProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let isSync = request.url?.path.contains("transactions/sync") ?? false
            let body: Data
            if isSync {
                let json = """
                {"added": [{"transaction_id": "\(UITestScenario.transactionImportMergePromptPlaidTransactionID)", \
                "amount": \(UITestScenario.transactionImportMergePromptAmount), \
                "date": "\(UITestScenario.todayDateString)", \
                "merchant_name": "\(UITestScenario.transactionImportMergePromptMerchantName)", \
                "name": "\(UITestScenario.transactionImportMergePromptMerchantName)"}], \
                "modified": [], "removed": [], "next_cursor": "uitest-cursor-1", "has_more": false}
                """
                body = Data(json.utf8)
            } else {
                body = Data(#"{}"#.utf8)
            }
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

    /// The `URLSession` `PlaidDebugLinkView` should hand to `PlaidServiceLive` and
    /// `TransactionImportService`. Under normal (non-UI-test) launches this is just
    /// `.shared`. Launched under XCUITest with `UITEST_FORCE_PLAID_ERROR=1` set, every
    /// Plaid REST call is intercepted and deterministically failed — see
    /// `PlaidForcedFailureURLProtocol`. Launched with
    /// `UITEST_PLAID_IMPORT_SCENARIO=mergePrompt` set, `/transactions/sync` calls are
    /// intercepted and answered with the scripted merge-prompt fixture above — see
    /// `PlaidImportMergePromptURLProtocol`.
    static var plaidURLSession: URLSession {
        if ProcessInfo.processInfo.environment["UITEST_FORCE_PLAID_ERROR"] == "1" {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [PlaidForcedFailureURLProtocol.self]
            return URLSession(configuration: configuration)
        }
        if ProcessInfo.processInfo.environment["UITEST_PLAID_IMPORT_SCENARIO"] == "mergePrompt" {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [PlaidImportMergePromptURLProtocol.self]
            return URLSession(configuration: configuration)
        }
        return .shared
    }

    /// Seeds a fake linked-item + Keychain access token before the app finishes
    /// launching, when `UITEST_SEED_PLAID_LINKED_ITEM=1` / `UITEST_SEED_PLAID_TOKEN=1`
    /// are set — `TransactionImportUITests` needs both so `PlaidDebugLinkView`'s
    /// "Import transactions" button is enabled (`service.linkedItem != nil`) and
    /// `TransactionImportService.runImport()` gets past its "no stored token, no-op"
    /// guard, without ever driving a real Plaid Link session. Mirrors
    /// `resetPlaidKeychainIfRequested()`'s persistence shapes exactly (see
    /// `PlaidServiceLive.persist(_:)`/`PlaidKeychainKey`) — duplicated here rather than
    /// called through `PlaidServiceLive` since those methods are `private` to that file
    /// and this only needs to write the same two, already-documented storage locations.
    static func seedPlaidLinkedItemIfRequested() {
        guard ProcessInfo.processInfo.environment["UITEST_SEED_PLAID_LINKED_ITEM"] == "1" else { return }
        let dict: [String: Any] = [
            "itemID": "uitest-item",
            "institutionName": "UITest Bank",
            "linkedAt": Date().timeIntervalSince1970,
        ]
        UserDefaults.standard.set(dict, forKey: "plaid.linkedItem")
    }

    /// See `seedPlaidLinkedItemIfRequested()` above. Blocks synchronously, same
    /// `DispatchSemaphore` bridging pattern as `resetPlaidKeychainIfRequested()`, so the
    /// token is guaranteed present before `ReservoirApp`'s first view appears.
    static func seedPlaidTokenIfRequested() {
        guard ProcessInfo.processInfo.environment["UITEST_SEED_PLAID_TOKEN"] == "1" else { return }
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            try? await KeychainService().save("uitest-fake-access-token", for: PlaidKeychainKey.accessToken)
            semaphore.signal()
        }
        semaphore.wait()
    }

    /// Deletes the app's stored Plaid access token before the app finishes
    /// launching, when `UITEST_RESET_PLAID_KEYCHAIN=1` is set — keeps
    /// `PlaidDebugLinkUITests.testVerifyTokenStoredReportsNoTokenWhenNothingLinked`
    /// deterministic regardless of what a prior real Sandbox Link session (or
    /// leftover simulator state — Keychain entries with
    /// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` survive app
    /// reinstall) may have left behind on this simulator, matching
    /// `KeychainServiceTests`' per-test namespacing strategy for the one
    /// call site (the debug view) that deliberately uses the real,
    /// unnamespaced production Keychain service.
    ///
    /// Blocks synchronously (a `DispatchSemaphore` bridging
    /// `KeychainService`'s `async` API) so the reset is guaranteed to
    /// complete before `ReservoirApp`'s first view appears — called from
    /// `ReservoirApp.init()`, a synchronous context, and this only ever runs
    /// under `DEBUG` + an XCUITest launch, so the brief blocking wait for a
    /// single fast Keychain delete is an acceptable, deliberate tradeoff for
    /// launch-time determinism.
    static func resetPlaidKeychainIfRequested() {
        guard ProcessInfo.processInfo.environment["UITEST_RESET_PLAID_KEYCHAIN"] == "1" else { return }
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            try? await KeychainService().delete(for: PlaidKeychainKey.accessToken)
            semaphore.signal()
        }
        semaphore.wait()
    }

    /// Resets the persisted Plaid Sandbox/Production toggle to its default
    /// (Sandbox) before the app finishes launching, when
    /// `UITEST_RESET_PLAID_ENVIRONMENT=1` is set — mirrors
    /// `resetPlaidKeychainIfRequested()` above for the equivalent problem on
    /// the `plaid.environment` `UserDefaults` key (see `PlaidEnvironmentStore`).
    /// Without this, `testConfirmingProductionSwitchesEnvironment` writes
    /// real `UserDefaults.standard` state with no reset mechanism: a mid-test
    /// failure (or any run that doesn't reach its own "switch back to
    /// Sandbox" step) leaves "Production" stuck, breaking
    /// `testEnvironmentPickerDefaultsToSandbox` on a later run (PR #12 review
    /// finding). No async Keychain work is needed here, so — unlike the
    /// Keychain reset above — this can just remove the UserDefaults key
    /// directly, synchronously.
    static func resetPlaidEnvironmentIfRequested() {
        guard ProcessInfo.processInfo.environment["UITEST_RESET_PLAID_ENVIRONMENT"] == "1" else { return }
        UserDefaults.standard.removeObject(forKey: "plaid.environment")
    }

    /// Seeds `context` with this scenario's fixtures and saves.
    func seed(into context: ModelContext) {
        switch self {
        case .emptyGoal:
            break

        case .normal:
            let startDate = Calendar.current.date(byAdding: .day, value: -5, to: .now)!
            let goal = SavingsGoal(
                targetAmount: 1000,
                targetDate: Calendar.current.date(byAdding: .day, value: 10, to: .now)!,
                startDate: startDate,
                startingBalance: 100,
                dailyBase: 30,
                // createdAt == startDate (not the default `.now`) so the createdAt floor
                // (adq.5) doesn't collapse this scenario's carry-forward history — these
                // fixtures simulate a goal that has genuinely existed since startDate, not
                // one created moments ago. See TodayScreenCalculator.carryForwardInput.
                createdAt: startDate
            )
            context.insert(goal)
            context.insert(SpendTransaction(
                amount: 12.50,
                date: .now,
                merchantName: "Coffee Shop",
                type: .variable,
                entryMethod: .manual,
                savingsGoal: goal
            ))
            context.insert(SpendTransaction(
                amount: 45,
                date: .now,
                merchantName: "Rent",
                type: .fixed,
                entryMethod: .manual,
                savingsGoal: goal
            ))

        case .completedGoalBanner:
            // No spend entries recorded at all, so cumulative carry-forward through
            // targetDate is a full 30 days' worth of dailyBase — comfortably >= 0, i.e.
            // the "met" banner variant (reservoir-4za).
            let startDate = Calendar.current.date(byAdding: .day, value: -30, to: .now)!
            let goal = SavingsGoal(
                targetAmount: 500,
                targetDate: Calendar.current.date(byAdding: .day, value: -1, to: .now)!,
                startDate: startDate,
                startingBalance: 0,
                dailyBase: 20,
                // See .normal above — createdAt == startDate preserves this scenario's
                // full 30-day carry-forward history under the adq.5 createdAt floor.
                createdAt: startDate
            )
            context.insert(goal)

        case .completedGoalBannerNotMet:
            // A single, large overspend entry that dwarfs the rest of the goal's
            // lifetime underspend, leaving cumulative carry-forward negative through
            // targetDate — the "not met" banner variant (reservoir-4za).
            let startDate = Calendar.current.date(byAdding: .day, value: -30, to: .now)!
            let goal = SavingsGoal(
                targetAmount: 500,
                targetDate: Calendar.current.date(byAdding: .day, value: -1, to: .now)!,
                startDate: startDate,
                startingBalance: 0,
                dailyBase: 20,
                createdAt: startDate
            )
            context.insert(goal)
            context.insert(SpendTransaction(
                amount: 5000,
                date: Calendar.current.date(byAdding: .day, value: -29, to: .now)!,
                merchantName: "Big Overspend",
                type: .variable,
                entryMethod: .manual,
                savingsGoal: goal
            ))

        case .goalsScreenMixed:
            let activeStartDate = Calendar.current.date(byAdding: .day, value: -10, to: .now)!
            let activeGoal = SavingsGoal(
                targetAmount: 1000,
                targetDate: Calendar.current.date(byAdding: .day, value: 20, to: .now)!,
                startDate: activeStartDate,
                startingBalance: 0,
                dailyBase: 20,
                createdAt: activeStartDate
            )
            context.insert(activeGoal)

            let completedStartDate = Calendar.current.date(byAdding: .day, value: -30, to: .now)!
            let completedGoal = SavingsGoal(
                targetAmount: 500,
                targetDate: Calendar.current.date(byAdding: .day, value: -1, to: .now)!,
                startDate: completedStartDate,
                startingBalance: 0,
                dailyBase: 20,
                createdAt: completedStartDate
            )
            context.insert(completedGoal)

        case .completedGoalBannerWithOrphanedSpend:
            let startDate = Calendar.current.date(byAdding: .day, value: -30, to: .now)!
            let goal = SavingsGoal(
                targetAmount: 500,
                targetDate: Calendar.current.date(byAdding: .day, value: -1, to: .now)!,
                startDate: startDate,
                startingBalance: 0,
                dailyBase: 20,
                createdAt: startDate
            )
            context.insert(goal)
            context.insert(SpendTransaction(
                amount: 20,
                date: .now,
                merchantName: "Orphaned Purchase",
                type: .variable,
                entryMethod: .manual,
                savingsGoal: nil
            ))

        case .transactionsList:
            let startDate = Calendar.current.date(byAdding: .day, value: -10, to: .now)!
            let goal = SavingsGoal(
                targetAmount: 1000,
                targetDate: Calendar.current.date(byAdding: .day, value: 20, to: .now)!,
                startDate: startDate,
                startingBalance: 0,
                dailyBase: 20,
                createdAt: startDate
            )
            context.insert(goal)
            context.insert(SpendTransaction(
                amount: 12.50,
                date: .now,
                merchantName: "Coffee Shop",
                type: .variable,
                entryMethod: .manual,
                savingsGoal: goal
            ))
            context.insert(SpendTransaction(
                amount: 900,
                date: .now,
                merchantName: "Rent",
                type: .fixed,
                entryMethod: .manual,
                savingsGoal: nil
            ))
            context.insert(SpendTransaction(
                amount: 30,
                date: Calendar.current.date(byAdding: .day, value: -1, to: .now)!,
                merchantName: "Grocery Store",
                type: .variable,
                entryMethod: .manual,
                savingsGoal: goal
            ))

        case .transactionsZeroGoals:
            break

        case .merchantRulesManage:
            context.insert(MerchantRule(merchantName: "Starbucks", type: .variable))
            context.insert(MerchantRule(merchantName: "Amazon", type: .fixed))

        case .merchantRulesRetag:
            context.insert(SpendTransaction(
                amount: 25,
                date: .now,
                merchantName: "Uber",
                type: .variable,
                entryMethod: .manual,
                isManualOverride: false
            ))
            context.insert(SpendTransaction(
                amount: 40,
                date: .now,
                merchantName: "Uber",
                type: .variable,
                entryMethod: .manual,
                isManualOverride: true
            ))

        case .transactionImportMergePrompt:
            context.insert(SpendTransaction(
                amount: Self.transactionImportMergePromptAmount,
                date: Self.todayForImportTests,
                merchantName: Self.transactionImportMergePromptMerchantName,
                type: .variable,
                entryMethod: .manual
            ))
        }

        try? context.save()
    }
}
#endif
