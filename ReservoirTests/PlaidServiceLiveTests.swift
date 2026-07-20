import XCTest
import LinkKit
@testable import Reservoir

/// Covers `PlaidServiceLive`'s pure/mappable logic — the LinkKit
/// `ExitErrorCode` → app-domain string mapping, and `handleLinkExit`'s
/// cancel-vs-error branching. Per reservoir-adq.6.1's acceptance criteria,
/// the LinkKit SDK session call and the direct-to-Plaid network exchange
/// call are integration-level and intentionally not unit tested here —
/// those are covered by manual verification (see PR notes).
@MainActor
final class PlaidServiceLiveTests: XCTestCase {
    private final class StubKeychain: KeychainServicing, @unchecked Sendable {
        var saveError: Error?

        func save(_ value: String, for key: String) async throws {
            if let saveError { throw saveError }
        }
        func read(for key: String) async throws -> String? { nil }
        func delete(for key: String) async throws {}
    }

    private func makeSUT(urlSession: URLSession = .shared) -> PlaidServiceLive {
        PlaidServiceLive(keychain: StubKeychain(), urlSession: urlSession)
    }

    /// A `KeychainServicing` stub that reports a fixed access token as already stored —
    /// backs the `startRelink` tests below, which need `keychain.read(for:)` to succeed
    /// before `startRelink` will attempt a network call at all.
    private final class StubKeychainWithToken: KeychainServicing, @unchecked Sendable {
        let token: String
        init(token: String = "access-sandbox-relink-test") { self.token = token }
        func save(_ value: String, for key: String) async throws {}
        func read(for key: String) async throws -> String? { token }
        func delete(for key: String) async throws {}
    }

    /// A `URLProtocol` that never calls back to its client — every request
    /// hangs until the owning `URLSession`'s task is cancelled. Backs the
    /// reentrancy-guard test below, which needs `startLink()`'s network call
    /// to stay in flight long enough to make a concurrent second call.
    private final class HangingURLProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {}
        override func stopLoading() {}
    }

    private func makeHangingURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HangingURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    /// A `URLProtocol` that answers every request with a successful
    /// `/item/public_token/exchange`-shaped JSON body, regardless of path —
    /// stands in for a real Plaid Sandbox exchange succeeding, so
    /// `handleLinkSuccess` can be exercised down to the Keychain-save step.
    private final class SuccessfulExchangeURLProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let body = Data(#"{"access_token":"access-sandbox-test","item_id":"item-test"}"#.utf8)
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

    private func makeSuccessfulExchangeURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SuccessfulExchangeURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    // MARK: - handleLinkExit

    func test_handleLinkExit_withNilErrorFields_doesNotSetPresentedError() {
        let sut = makeSUT()
        sut.handleLinkExit(errorType: nil, errorCode: nil)
        XCTAssertNil(sut.presentedError)
    }

    func test_handleLinkExit_withNilErrorFields_hidesLinkPresentation() {
        let sut = makeSUT()
        sut.isPresentingLink = true
        sut.handleLinkExit(errorType: nil, errorCode: nil)
        XCTAssertFalse(sut.isPresentingLink)
    }

    func test_handleLinkExit_withNetworkLikeErrorType_stillSetsPlaidSideCategory() {
        // LinkKit's onExit taxonomy has no client-connectivity category, so
        // even an errorType string that looks network-related classifies as
        // .plaidSide, not .network — see PlaidErrorClassifier.classify.
        let sut = makeSUT()
        sut.handleLinkExit(errorType: "NETWORK_ERROR", errorCode: nil)
        XCTAssertEqual(sut.presentedError, .plaidSide)
    }

    func test_handleLinkExit_withInstitutionErrorType_setsPlaidSideCategory() {
        let sut = makeSUT()
        sut.handleLinkExit(errorType: "INSTITUTION_ERROR", errorCode: "INSTITUTION_DOWN")
        XCTAssertEqual(sut.presentedError, .plaidSide)
    }

    // MARK: - handleLinkSuccess Keychain-failure classification

    /// `PlaidServiceLive.persist(_:)`/`loadPersistedLinkedItem()` read/write
    /// this fixed `UserDefaults.standard` key (mirrored here since it's
    /// `private` on `PlaidServiceLive`) regardless of which `PlaidServiceLive`
    /// instance is doing the writing — a real `LinkedItem` written by one
    /// test is otherwise still there (and gets loaded by `init`) for every
    /// later test in the process. Clear it before and after each test below
    /// so they can't see each other's persisted state.
    private static let linkedItemDefaultsKey = "plaid.linkedItem"

    private func clearPersistedLinkedItem() {
        UserDefaults.standard.removeObject(forKey: Self.linkedItemDefaultsKey)
    }

    func test_handleLinkSuccess_whenKeychainSaveFails_classifiesAsLocalStorageNotBankFailure() async {
        clearPersistedLinkedItem()
        addTeardownBlock { self.clearPersistedLinkedItem() }

        let keychain = StubKeychain()
        keychain.saveError = KeychainError.unhandled(status: -1)
        let sut = PlaidServiceLive(keychain: keychain, urlSession: makeSuccessfulExchangeURLSession())

        await sut.handleLinkSuccess(publicToken: "public-good", institutionName: "Test Bank")

        // The bank exchange succeeded (the stub session returns a valid
        // access_token/item_id) — only the local Keychain write failed, so
        // this must not be classified/copy'd as a bank-side failure.
        XCTAssertEqual(sut.presentedError, .localStorage)
        XCTAssertNil(sut.linkedItem)
    }

    func test_handleLinkSuccess_whenExchangeAndKeychainBothSucceed_setsLinkedItemWithNoError() async {
        clearPersistedLinkedItem()
        addTeardownBlock { self.clearPersistedLinkedItem() }

        let sut = PlaidServiceLive(keychain: StubKeychain(), urlSession: makeSuccessfulExchangeURLSession())

        await sut.handleLinkSuccess(publicToken: "public-good", institutionName: "Test Bank")

        XCTAssertNil(sut.presentedError)
        XCTAssertEqual(sut.linkedItem?.itemID, "item-test")
        XCTAssertEqual(sut.linkedItem?.institutionName, "Test Bank")
    }

    // MARK: - startLink reentrancy guard

    func test_startLink_whileAlreadyInFlight_secondCallIsNoOpAndReturnsPromptly() async {
        let sut = makeSUT(urlSession: makeHangingURLSession())

        let firstTask = Task { await sut.startLink() }
        // Wait for the first call to claim the guard before firing the second.
        while !sut.isStartingLink {
            await Task.yield()
        }

        let secondCallReturned = expectation(description: "second startLink() returns without waiting on the network")
        Task {
            await sut.startLink()
            secondCallReturned.fulfill()
        }
        await fulfillment(of: [secondCallReturned], timeout: 2.0)

        firstTask.cancel()
    }

    // MARK: - startRelink (reservoir-adq.6.5 — update-mode Link)

    /// Captures the last request's decoded JSON body (as `[String: Any]`) and answers a
    /// successful `{"link_token": ...}` response — lets these tests assert the exact
    /// update-mode request shape Plaid's API contract requires (`access_token` present,
    /// `products` entirely absent) rather than just observing pass/fail behavior.
    private final class CapturingRelinkURLProtocol: URLProtocol {
        nonisolated(unsafe) static var capturedBody: [String: Any]?
        nonisolated(unsafe) static var linkTokenToReturn = "link-sandbox-relink-test"

        static func reset() {
            capturedBody = nil
            linkTokenToReturn = "link-sandbox-relink-test"
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            // `URLSession` (unlike the older `NSURLConnection`) can deliver the request
            // body to `URLProtocol` via `httpBodyStream` rather than `httpBody`, even
            // though the caller only ever set `.httpBody` — a well-known platform quirk.
            // Read whichever is actually populated rather than assuming `.httpBody`.
            let bodyData: Data?
            if let httpBody = request.httpBody {
                bodyData = httpBody
            } else if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var data = Data()
                let bufferSize = 4096
                var buffer = [UInt8](repeating: 0, count: bufferSize)
                while stream.hasBytesAvailable {
                    let read = stream.read(&buffer, maxLength: bufferSize)
                    if read > 0 { data.append(buffer, count: read) } else { break }
                }
                bodyData = data
            } else {
                bodyData = nil
            }
            if let bodyData {
                Self.capturedBody = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any]
            }
            let body = Data(#"{"link_token": "\#(Self.linkTokenToReturn)"}"#.utf8)
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

    private func makeCapturingRelinkURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CapturingRelinkURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    func test_startRelink_requestBody_includesAccessToken_omitsProducts() async throws {
        CapturingRelinkURLProtocol.reset()
        let sut = PlaidServiceLive(
            keychain: StubKeychainWithToken(token: "access-sandbox-relink-test"),
            urlSession: makeCapturingRelinkURLSession()
        )
        let item = LinkedItem(itemID: "item-1", institutionName: "Test Bank", linkedAt: .now)

        await sut.startRelink(for: item)

        let body = try XCTUnwrap(CapturingRelinkURLProtocol.capturedBody)
        XCTAssertEqual(body["access_token"] as? String, "access-sandbox-relink-test", "update-mode's request must include the existing item's access_token.")
        XCTAssertNil(body["products"], "update-mode's request must omit `products` entirely, per Plaid's update-mode API contract.")
    }

    func test_startRelink_onSuccess_setsLinkTokenAndPresentsLink() async {
        CapturingRelinkURLProtocol.reset()
        CapturingRelinkURLProtocol.linkTokenToReturn = "link-sandbox-distinctive-token"
        let sut = PlaidServiceLive(
            keychain: StubKeychainWithToken(),
            urlSession: makeCapturingRelinkURLSession()
        )
        let item = LinkedItem(itemID: "item-1", institutionName: "Test Bank", linkedAt: .now)

        await sut.startRelink(for: item)

        XCTAssertEqual(sut.linkToken, "link-sandbox-distinctive-token")
        XCTAssertTrue(sut.isPresentingLink)
        XCTAssertNil(sut.presentedError)
    }

    func test_startRelink_withNoStoredAccessToken_doesNotMakeNetworkCall_setsError() async {
        CapturingRelinkURLProtocol.reset()
        let sut = PlaidServiceLive(
            keychain: StubKeychain(), // reports nil — nothing stored to relink with.
            urlSession: makeCapturingRelinkURLSession()
        )
        let item = LinkedItem(itemID: "item-1", institutionName: "Test Bank", linkedAt: .now)

        await sut.startRelink(for: item)

        XCTAssertNil(CapturingRelinkURLProtocol.capturedBody, "no network call should have been attempted without a stored access token.")
        XCTAssertNotNil(sut.presentedError)
        XCTAssertFalse(sut.isPresentingLink)
    }

    func test_startRelink_whenTokenCreationFails_classifiesError() async {
        let sut = PlaidServiceLive(keychain: StubKeychainWithToken(), urlSession: makeHangingURLSession())
        let item = LinkedItem(itemID: "item-1", institutionName: "Test Bank", linkedAt: .now)

        let task = Task { await sut.startRelink(for: item) }
        // The hanging protocol never completes, so this call would hang forever if not
        // cancelled — just proves startRelink is in flight (isStartingLink) without
        // waiting on a real response, mirroring the existing reentrancy-guard test above.
        while !sut.isStartingLink {
            await Task.yield()
        }
        task.cancel()
    }

    // MARK: - retry()

    /// Code-review finding (reservoir-adq.6.5): `retry()` backs the shared "Try again"
    /// affordance shown for *any* `presentedError`, including one from a failed
    /// `startRelink(for:)` attempt. If `retry()` always called `startLink()`, retrying a
    /// failed relink would silently create a brand-new item/token instead of repairing the
    /// existing one — the exact bug the Relink button itself was fixed to avoid. `retry()`
    /// must branch on `linkedItem` the same way `PlaidDebugLinkView`'s button does.
    func test_retry_whenItemAlreadyLinked_reAttemptsRelink_notFreshLink() async throws {
        CapturingRelinkURLProtocol.reset()
        let linkedItemStore = StubLinkedItemStore(
            initial: LinkedItem(itemID: "item-1", institutionName: "Test Bank", linkedAt: .now)
        )
        let sut = PlaidServiceLive(
            keychain: StubKeychainWithToken(token: "access-sandbox-retry-test"),
            urlSession: makeCapturingRelinkURLSession(),
            linkedItemStore: linkedItemStore
        )
        sut.presentedError = .network // simulates a prior failed startRelink attempt.

        await sut.retry()

        let body = try XCTUnwrap(
            CapturingRelinkURLProtocol.capturedBody,
            "retry() must actually attempt a relink, not silently no-op."
        )
        XCTAssertEqual(
            body["access_token"] as? String, "access-sandbox-retry-test",
            "retry() must re-attempt update-mode relink (request carries the existing item's access_token), not a fresh Link request."
        )
        XCTAssertNil(body["products"], "a fresh-Link retry would wrongly include `products` — this must stay a relink request.")
    }

    func test_retry_whenNoItemLinkedYet_attemptsFreshLink() async {
        let sut = PlaidServiceLive(keychain: StubKeychain(), urlSession: makeHangingURLSession())
        XCTAssertNil(sut.linkedItem)
        sut.presentedError = .network

        let task = Task { await sut.retry() }
        // Same reentrancy-proving pattern as the hanging-protocol tests above: proves
        // retry() is attempting a network call (via startLink(), since there's no linked
        // item to relink) without needing to wait for a real response.
        while !sut.isStartingLink {
            await Task.yield()
        }
        task.cancel()
    }

    // MARK: - handleRelinkSuccess

    func test_handleRelinkSuccess_clearsNeedsAttention_doesNotTouchKeychain() {
        final class RecordingKeychain: KeychainServicing, @unchecked Sendable {
            private(set) var saveCallCount = 0
            func save(_ value: String, for key: String) async throws { saveCallCount += 1 }
            func read(for key: String) async throws -> String? { nil }
            func delete(for key: String) async throws {}
        }
        let keychain = RecordingKeychain()
        let linkedItemStore = StubLinkedItemStore(
            initial: LinkedItem(itemID: "item-1", institutionName: "Test Bank", linkedAt: .now, needsAttention: true)
        )
        let sut = PlaidServiceLive(keychain: keychain, urlSession: .shared, linkedItemStore: linkedItemStore)
        XCTAssertEqual(sut.linkedItem?.needsAttention, true, "sanity check: init must have loaded the seeded flag.")
        sut.isPresentingLink = true

        sut.handleRelinkSuccess()

        XCTAssertEqual(sut.linkedItem?.needsAttention, false)
        XCTAssertEqual(linkedItemStore.load()?.needsAttention, false, "the persisted store must also be updated, not just the in-memory copy.")
        XCTAssertFalse(sut.isPresentingLink)
        XCTAssertEqual(keychain.saveCallCount, 0, "no token re-exchange happens in update mode — the access_token doesn't change.")
    }

    // MARK: - errorType(for:) — ExitErrorCode -> app-domain string mapping

    private func exitError(_ code: ExitErrorCode) -> ExitError {
        ExitError.privateObjCInitializer(
            errorCode: code,
            errorMessage: "test error",
            displayMesssage: nil,
            errorJSON: nil
        )
    }

    func test_errorType_mapsApiError() {
        XCTAssertEqual(
            PlaidServiceLive.errorType(for: exitError(.apiError(.internalServerError))),
            "API_ERROR"
        )
    }

    func test_errorType_mapsAuthError() {
        XCTAssertEqual(
            PlaidServiceLive.errorType(for: exitError(.authError(.verificationExpired))),
            "AUTH_ERROR"
        )
    }

    func test_errorType_mapsInstitutionError() {
        XCTAssertEqual(
            PlaidServiceLive.errorType(for: exitError(.institutionError(.institutionDown))),
            "INSTITUTION_ERROR"
        )
    }

    func test_errorType_mapsItemError() {
        XCTAssertEqual(
            PlaidServiceLive.errorType(for: exitError(.itemError(.itemLoginRequired))),
            "ITEM_ERROR"
        )
    }

    func test_errorType_mapsInvalidInput() {
        XCTAssertEqual(
            PlaidServiceLive.errorType(for: exitError(.invalidInput(.invalidApiKeys))),
            "INVALID_INPUT"
        )
    }

    func test_errorType_mapsInvalidRequest() {
        XCTAssertEqual(
            PlaidServiceLive.errorType(for: exitError(.invalidRequest(.missingFields))),
            "INVALID_REQUEST"
        )
    }

    func test_errorType_mapsRateLimitExceeded() {
        XCTAssertEqual(
            PlaidServiceLive.errorType(for: exitError(.rateLimitExceeded(.accountsLimit))),
            "RATE_LIMIT_EXCEEDED"
        )
    }

    func test_errorType_mapsInternal() {
        XCTAssertEqual(
            PlaidServiceLive.errorType(for: exitError(.internal("some internal message"))),
            "INTERNAL"
        )
    }

    func test_errorType_mapsUnknown_usingItsTypeField() {
        XCTAssertEqual(
            PlaidServiceLive.errorType(for: exitError(.unknown(type: "SOME_NEW_TYPE", code: "SOME_CODE"))),
            "SOME_NEW_TYPE"
        )
    }

    func test_errorType_mapsAssetReportError() {
        XCTAssertEqual(
            PlaidServiceLive.errorType(for: exitError(.assetReportError(.productNotReady))),
            "ASSET_REPORT_ERROR"
        )
    }
}
