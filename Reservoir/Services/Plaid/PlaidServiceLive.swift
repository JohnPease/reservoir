import Foundation
import Observation
import LinkKit

/// Reads Plaid Sandbox credentials embedded into the app's Info.plist at
/// build time from `Config/Plaid.xcconfig` (gitignored, see README and
/// `Config/Plaid.xcconfig.example`). Never committed — acceptable only
/// under this app's accepted risk posture for in-app API keys (personal,
/// sideloaded, single-user, not distributed; see PROJECT_SPEC.md).
private enum PlaidCredentials {
    static var clientID: String {
        Bundle.main.object(forInfoDictionaryKey: "PlaidClientID") as? String ?? ""
    }
    static var sandboxSecret: String {
        Bundle.main.object(forInfoDictionaryKey: "PlaidSandboxSecret") as? String ?? ""
    }
}

/// OAuth-institution redirects use a universal link, not a custom URL
/// scheme — Plaid requires an https redirect URI. This host must match
/// `Reservoir.entitlements`' Associated Domains entry (`project.yml`) and
/// be registered as an "Allowed redirect URI" in the Plaid dashboard. Not a
/// secret, so it's a plain constant rather than xcconfig-injected.
enum PlaidOAuthRedirect {
    static let url = URL(string: "https://johnpease.github.io/oauth")!
}

/// Live implementation of `PlaidService`: owns the LinkKit session lifecycle
/// and calls Plaid's REST API directly from the device to create a link
/// token and to exchange a `public_token` for an `access_token` — Sandbox
/// only (reservoir-adq.6.1's scope; Sandbox/Production switching is
/// reservoir-adq.6.2). This file, along with `PlaidLinkPresentationView`, is
/// the only place `LinkKit` is imported (STANDARDS §4 / reservoir-adq.6.1's
/// acceptance criteria) — `PlaidService`'s own protocol surface has no
/// LinkKit types.
@Observable
@MainActor
final class PlaidServiceLive: PlaidService {
    var isPresentingLink = false
    private(set) var linkToken: String?
    private(set) var isExchangingToken = false
    private(set) var linkedItem: LinkedItem?
    var presentedError: PlaidErrorCategory?

    /// True while `startLink()` is in flight (from the moment it's called
    /// until the link token request settles, success or failure). Guards
    /// against a double-tap race: two concurrent `startLink()` calls would
    /// otherwise both create link tokens/sessions and race to set
    /// `linkToken`/`linkSession`/`isPresentingLink`, silently discarding
    /// whichever session lost. `PlaidDebugLinkView` also disables its "Link a
    /// bank account" button while this is true, but the guard here is the
    /// actual fix — belt and suspenders against any other future call site.
    private(set) var isStartingLink = false

    /// The active LinkKit session backing the current `linkToken`. Exposed
    /// (not part of the `PlaidService` protocol) so `PlaidLinkPresentationView`
    /// — the one other file allowed to depend on `LinkKit` — can present its
    /// `.sheet()`. Must be retained for the lifetime of the presentation per
    /// LinkKit 7.x's session-based API; LinkKit does not retain it itself.
    private(set) var linkSession: PlaidLinkSession?

    private let keychain: KeychainServicing
    private let urlSession: URLSession
    private let baseURL = URL(string: "https://sandbox.plaid.com")!

    init(keychain: KeychainServicing = KeychainService(), urlSession: URLSession = .shared) {
        self.keychain = keychain
        self.urlSession = urlSession
        self.linkedItem = Self.loadPersistedLinkedItem()
    }

    func startLink() async {
        guard !isStartingLink else { return }
        isStartingLink = true
        defer { isStartingLink = false }

        presentedError = nil
        do {
            let token = try await createLinkToken()
            linkToken = token
            linkSession = try makeSession(token: token)
            isPresentingLink = true
        } catch {
            presentedError = PlaidErrorClassifier.classify(.exchangeError(error))
        }
    }

    func retry() async {
        presentedError = nil
        await startLink()
    }

    func handleLinkSuccess(publicToken: String, institutionName: String) async {
        isPresentingLink = false
        linkSession = nil
        isExchangingToken = true
        defer { isExchangingToken = false }

        let exchange: (accessToken: String, itemID: String)
        do {
            exchange = try await exchangePublicToken(publicToken)
        } catch {
            presentedError = PlaidErrorClassifier.classify(.exchangeError(error))
            return
        }

        // Persist only after a fully successful exchange — if the save below
        // throws, nothing has been written yet, so there is no partial/
        // orphaned state to roll back (reservoir-adq.6.1's "Token exchange
        // failure" UX requirement). A save failure here is classified
        // separately from an exchange failure (.localStorage vs. .network/
        // .plaidSide): the bank exchange itself succeeded, so "Couldn't
        // connect to your bank" would be the wrong message — the failure is
        // local Keychain storage, not Plaid.
        do {
            try await keychain.save(exchange.accessToken, for: PlaidKeychainKey.accessToken)
        } catch {
            presentedError = PlaidErrorClassifier.classify(.localStorageError(error))
            return
        }

        let item = LinkedItem(itemID: exchange.itemID, institutionName: institutionName, linkedAt: Date())
        linkedItem = item
        Self.persist(item)
    }

    func handleLinkExit(errorType: String?, errorCode: String?) {
        isPresentingLink = false
        linkSession = nil
        guard errorType != nil || errorCode != nil else {
            // Plain user cancel — silent, no error UI (UX spec).
            return
        }
        presentedError = PlaidErrorClassifier.classify(
            .linkError(errorType: errorType, errorCode: errorCode)
        )
    }

    // MARK: - LinkKit session creation

    private func makeSession(token: String) throws -> PlaidLinkSession {
        let configuration = LinkTokenConfiguration(
            token: token,
            onSuccess: { [weak self] success in
                let publicToken = success.publicToken
                let institutionName = success.metadata.institution.name
                Task { @MainActor in
                    await self?.handleLinkSuccess(publicToken: publicToken, institutionName: institutionName)
                }
            },
            onExit: { [weak self] exit in
                let errorType = exit.error.map(Self.errorType(for:))
                let errorCode = exit.error?.errorCode.description
                Task { @MainActor in
                    self?.handleLinkExit(errorType: errorType, errorCode: errorCode)
                }
            },
            onEvent: nil,
            onLoad: nil
        )
        return try Plaid.createPlaidLinkSession(configuration: configuration)
    }

    /// Reduces LinkKit's typed `ExitErrorCode` down to the free-text
    /// `errorType`/`errorCode` strings `PlaidErrorClassifier` (a LinkKit-free
    /// pure function) matches against. This mapping is the one place LinkKit's
    /// error taxonomy is translated into the app's domain — keeping it here
    /// is what lets the classifier itself stay reusable and dependency-free.
    static func errorType(for error: LinkKit.ExitError) -> String {
        switch error.errorCode {
        case .apiError: return "API_ERROR"
        case .authError: return "AUTH_ERROR"
        case .assetReportError: return "ASSET_REPORT_ERROR"
        case .internal: return "INTERNAL"
        case .institutionError: return "INSTITUTION_ERROR"
        case .itemError: return "ITEM_ERROR"
        case .invalidInput: return "INVALID_INPUT"
        case .invalidRequest: return "INVALID_REQUEST"
        case .rateLimitExceeded: return "RATE_LIMIT_EXCEEDED"
        case .unknown(let type, _): return type
        @unknown default: return "UNKNOWN"
        }
    }

    // MARK: - Plaid REST calls (direct from device, Sandbox only)

    private func createLinkToken() async throws -> String {
        struct RequestBody: Encodable {
            let client_id: String
            let secret: String
            let client_name: String
            let user: RequestUser
            let products: [String]
            let country_codes: [String]
            let language: String
            let redirect_uri: String

            struct RequestUser: Encodable { let client_user_id: String }
        }
        struct ResponseBody: Decodable { let link_token: String }

        let body = RequestBody(
            client_id: PlaidCredentials.clientID,
            secret: PlaidCredentials.sandboxSecret,
            client_name: "Reservoir",
            user: .init(client_user_id: Self.clientUserID),
            products: ["transactions"],
            country_codes: ["US"],
            language: "en",
            redirect_uri: PlaidOAuthRedirect.url.absoluteString
        )
        let response: ResponseBody = try await post("/link/token/create", body: body)
        return response.link_token
    }

    private func exchangePublicToken(_ publicToken: String) async throws -> (accessToken: String, itemID: String) {
        struct RequestBody: Encodable {
            let client_id: String
            let secret: String
            let public_token: String
        }
        struct ResponseBody: Decodable {
            let access_token: String
            let item_id: String
        }

        let body = RequestBody(
            client_id: PlaidCredentials.clientID,
            secret: PlaidCredentials.sandboxSecret,
            public_token: publicToken
        )
        let response: ResponseBody = try await post("/item/public_token/exchange", body: body)
        return (response.access_token, response.item_id)
    }

    private func post<Body: Encodable, Response: Decodable>(_ path: String, body: Body) async throws -> Response {
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

    // MARK: - client_user_id / linked-item persistence

    /// A stable per-device identifier Plaid's `/link/token/create` requires
    /// as `user.client_user_id`. This app has no `User` entity (single-
    /// device, no auth — see PROJECT_SPEC.md's "No `User` entity" note),
    /// so a UUID is generated once and persisted in `UserDefaults`,
    /// consistent with how the spec places other app-wide, non-financial
    /// settings (linked accounts, notification prefs).
    private static var clientUserID: String {
        let key = "plaid.clientUserID"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let generated = UUID().uuidString
        UserDefaults.standard.set(generated, forKey: key)
        return generated
    }

    /// Non-secret linked-item metadata (institution name, item ID, linked
    /// date) — the `access_token` itself lives only in Keychain, never here.
    /// This is a `UserDefaults` convenience so the debug entry point can
    /// show "already linked" state across launches; it is not the storage
    /// decision for Settings' real account list (reservoir-adq.7/6.3), which
    /// may need a SwiftData model once more than metadata display is needed.
    private static let linkedItemDefaultsKey = "plaid.linkedItem"

    private static func persist(_ item: LinkedItem) {
        let dict: [String: Any] = [
            "itemID": item.itemID,
            "institutionName": item.institutionName,
            "linkedAt": item.linkedAt.timeIntervalSince1970,
        ]
        UserDefaults.standard.set(dict, forKey: linkedItemDefaultsKey)
    }

    private static func loadPersistedLinkedItem() -> LinkedItem? {
        guard let dict = UserDefaults.standard.dictionary(forKey: linkedItemDefaultsKey),
              let itemID = dict["itemID"] as? String,
              let institutionName = dict["institutionName"] as? String,
              let linkedAtInterval = dict["linkedAt"] as? TimeInterval
        else {
            return nil
        }
        return LinkedItem(
            itemID: itemID,
            institutionName: institutionName,
            linkedAt: Date(timeIntervalSince1970: linkedAtInterval)
        )
    }
}
