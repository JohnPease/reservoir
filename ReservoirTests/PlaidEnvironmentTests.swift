import XCTest
@testable import Reservoir

/// Covers reservoir-adq.6.2's environment-resolution logic: `PlaidEnvironment`
/// itself, `PlaidEnvironmentStore`'s persistence, and — the acceptance
/// criterion that matters most — that `PlaidServiceLive` re-reads the current
/// environment on every call (not just at init) and picks the matching base
/// URL, with the flag set both ways.
final class PlaidEnvironmentTests: XCTestCase {

    // MARK: - PlaidEnvironment

    func test_sandbox_baseURL_isSandboxHost() {
        XCTAssertEqual(PlaidEnvironment.sandbox.baseURL.host, "sandbox.plaid.com")
    }

    func test_production_baseURL_isProductionHost() {
        XCTAssertEqual(PlaidEnvironment.production.baseURL.host, "production.plaid.com")
    }

    func test_sandbox_displayName() {
        XCTAssertEqual(PlaidEnvironment.sandbox.displayName, "Sandbox")
    }

    func test_production_displayName() {
        XCTAssertEqual(PlaidEnvironment.production.displayName, "Production")
    }

    // MARK: - PlaidEnvironmentStore

    private func makeStore() -> PlaidEnvironmentStore {
        let suiteName = "PlaidEnvironmentTests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        return PlaidEnvironmentStore(defaults: UserDefaults(suiteName: suiteName)!)
    }

    func test_store_defaultsToSandbox_whenNothingPersisted() {
        let store = makeStore()
        XCTAssertEqual(store.current, .sandbox)
    }

    func test_store_persistsProduction_afterSet() {
        let store = makeStore()
        store.set(.production)
        XCTAssertEqual(store.current, .production)
    }

    func test_store_roundTripsBackToSandbox() {
        let store = makeStore()
        store.set(.production)
        store.set(.sandbox)
        XCTAssertEqual(store.current, .sandbox)
    }

    // MARK: - PlaidServiceLive resolves environment at call time

    private final class StubEnvironmentStore: PlaidEnvironmentStoring, @unchecked Sendable {
        var current: PlaidEnvironment
        init(_ initial: PlaidEnvironment) { self.current = initial }
        func set(_ environment: PlaidEnvironment) { current = environment }
    }

    /// Captures the last request's host, letting the test assert which
    /// `PlaidEnvironment` host `PlaidServiceLive` actually dialed without
    /// depending on real network access or real credentials.
    private final class CapturingURLProtocol: URLProtocol {
        // Set from `startLoading()`, which URLSession calls on a background
        // queue; read back from the test after `await`ing the call that
        // triggers it. Tests run sequentially and each resets this before
        // use, so unsynchronized access is safe here despite the compiler
        // not being able to prove it.
        nonisolated(unsafe) static var capturedHost: String?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.capturedHost = request.url?.host
            // Fail deterministically — this test only cares which host was
            // dialed, not a successful exchange.
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func makeCapturingURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CapturingURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    @MainActor
    func test_startLink_withSandboxEnvironment_dialsSandboxHost() async {
        CapturingURLProtocol.capturedHost = nil
        let sut = PlaidServiceLive(
            keychain: StubKeychain(),
            urlSession: makeCapturingURLSession(),
            environmentStore: StubEnvironmentStore(.sandbox)
        )
        await sut.startLink()
        XCTAssertEqual(CapturingURLProtocol.capturedHost, "sandbox.plaid.com")
    }

    @MainActor
    func test_startLink_withProductionEnvironment_dialsProductionHost() async {
        CapturingURLProtocol.capturedHost = nil
        let sut = PlaidServiceLive(
            keychain: StubKeychain(),
            urlSession: makeCapturingURLSession(),
            environmentStore: StubEnvironmentStore(.production)
        )
        await sut.startLink()
        XCTAssertEqual(CapturingURLProtocol.capturedHost, "production.plaid.com")
    }

    @MainActor
    func test_startLink_reReadsEnvironment_onEachCall_noRebuildNeeded() async {
        CapturingURLProtocol.capturedHost = nil
        let store = StubEnvironmentStore(.sandbox)
        let sut = PlaidServiceLive(
            keychain: StubKeychain(),
            urlSession: makeCapturingURLSession(),
            environmentStore: store
        )
        await sut.startLink()
        XCTAssertEqual(CapturingURLProtocol.capturedHost, "sandbox.plaid.com")

        // Flip the flag mid-"session" (as an in-app toggle would) and call
        // again — reservoir-adq.6.2's core acceptance criterion: no rebuild,
        // no new PlaidServiceLive instance required.
        store.set(.production)
        await sut.startLink()
        XCTAssertEqual(CapturingURLProtocol.capturedHost, "production.plaid.com")
    }

    // MARK: - Environment change invalidates the linked item / Keychain token

    /// Records `delete(for:)` calls so tests can assert the Keychain token
    /// was actually invalidated, not just that `linkedItem` went nil.
    private final class RecordingKeychain: KeychainServicing, @unchecked Sendable {
        private(set) var deletedKeys: [String] = []
        func save(_ value: String, for key: String) async throws {}
        func read(for key: String) async throws -> String? { nil }
        func delete(for key: String) async throws { deletedKeys.append(key) }
    }

    private static let linkedItemDefaultsKey = "plaid.linkedItem"

    /// A real `PlaidEnvironmentStore` is required here (not `StubEnvironmentStore`)
    /// since the invalidation hook lives on `PlaidEnvironmentStore.onChange`,
    /// which `PlaidServiceLive.init` wires up — an isolated `UserDefaults`
    /// suite keeps this from touching `.standard`.
    private func makeIsolatedStore() -> PlaidEnvironmentStore {
        let suiteName = "PlaidEnvironmentTests.invalidation.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        return PlaidEnvironmentStore(defaults: UserDefaults(suiteName: suiteName)!)
    }

    @MainActor
    func test_realEnvironmentChange_clearsLinkedItemAndDeletesKeychainToken() async {
        UserDefaults.standard.set(
            ["itemID": "item-old", "institutionName": "Old Bank", "linkedAt": Date().timeIntervalSince1970],
            forKey: Self.linkedItemDefaultsKey
        )
        addTeardownBlock { UserDefaults.standard.removeObject(forKey: Self.linkedItemDefaultsKey) }

        let store = makeIsolatedStore()
        let keychain = RecordingKeychain()
        let sut = PlaidServiceLive(keychain: keychain, urlSession: .shared, environmentStore: store)

        XCTAssertNotNil(sut.linkedItem, "sanity check: the pre-seeded linked item should have loaded at init")

        store.set(.production)

        // The Keychain delete is dispatched onto a `Task { @MainActor in }`
        // from a non-isolated closure — yield until it's had a chance to run.
        for _ in 0..<50 where keychain.deletedKeys.isEmpty {
            await Task.yield()
        }

        XCTAssertNil(sut.linkedItem)
        XCTAssertNil(UserDefaults.standard.dictionary(forKey: Self.linkedItemDefaultsKey))
        XCTAssertEqual(keychain.deletedKeys, [PlaidKeychainKey.accessToken])
    }

    @MainActor
    func test_settingSameEnvironment_doesNotClearLinkedItem() async {
        UserDefaults.standard.set(
            ["itemID": "item-keep", "institutionName": "Keep Bank", "linkedAt": Date().timeIntervalSince1970],
            forKey: Self.linkedItemDefaultsKey
        )
        addTeardownBlock { UserDefaults.standard.removeObject(forKey: Self.linkedItemDefaultsKey) }

        let store = makeIsolatedStore()
        let keychain = RecordingKeychain()
        let sut = PlaidServiceLive(keychain: keychain, urlSession: .shared, environmentStore: store)

        // Default/no-op set to the environment already in effect (sandbox) —
        // must not be treated as a real change.
        store.set(.sandbox)
        await Task.yield()

        XCTAssertNotNil(sut.linkedItem)
        XCTAssertTrue(keychain.deletedKeys.isEmpty)
    }
}
