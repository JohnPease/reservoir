import Foundation
import Observation
import LinkKit

/// Reads Plaid credentials embedded into the app's Info.plist at build time
/// from `Config/Plaid.xcconfig` (gitignored, see README and
/// `Config/Plaid.xcconfig.example`). Never committed — acceptable only
/// under this app's accepted risk posture for in-app API keys (personal,
/// sideloaded, single-user, not distributed; see PROJECT_SPEC.md).
///
/// `client_id` is a single value shared across Plaid's Sandbox and
/// Production environments (Plaid's own account model, not this app's
/// choice) — only the `secret` differs per environment, so there is one
/// `clientID` and two secrets here rather than two full credential pairs.
/// Not `private` — reused by `TransactionImportService` (adq.6.3) for its own direct
/// `/transactions/sync` call, which needs the same `client_id`/environment-scoped
/// `secret` this app's other direct-from-device Plaid REST calls use. Keeping credential
/// reading in this one place (rather than a second copy) is what STANDARDS §3 requires,
/// even though the two callers' network-call boilerplate itself isn't shared (see
/// `TransactionImportService`'s own `post(_:body:)` doc comment for why that duplication
/// is accepted).
enum PlaidCredentials {
    static var clientID: String {
        Bundle.main.object(forInfoDictionaryKey: "PlaidClientID") as? String ?? ""
    }
    static var sandboxSecret: String {
        Bundle.main.object(forInfoDictionaryKey: "PlaidSandboxSecret") as? String ?? ""
    }
    static var productionSecret: String {
        Bundle.main.object(forInfoDictionaryKey: "PlaidProductionSecret") as? String ?? ""
    }

    /// The `secret` to use for a given `PlaidEnvironment`. Pure function
    /// (no Bundle/Info.plist access) so reservoir-adq.6.2's acceptance
    /// criteria — environment-resolution logic unit tested with the flag
    /// set both ways — can be verified without a bundled Info.plist.
    static func secret(for environment: PlaidEnvironment, sandboxSecret: String, productionSecret: String) -> String {
        switch environment {
        case .sandbox: sandboxSecret
        case .production: productionSecret
        }
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
/// token and to exchange a `public_token` for an `access_token`. The
/// Sandbox/Production `PlaidEnvironment` is resolved from
/// `environmentStore` on every call (reservoir-adq.6.2), not cached at
/// init, so an in-app toggle takes effect on the next Link/import call
/// with no rebuild or relaunch. This file, along with
/// `PlaidLinkPresentationView`, is the only place `LinkKit` is imported
/// (STANDARDS §4 / reservoir-adq.6.1's acceptance criteria) —
/// `PlaidService`'s own protocol surface has no LinkKit types.
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

    /// Fires once `handleRelinkSuccess()` actually runs — i.e. once the update-mode Link
    /// session the user is shown has genuinely completed, not once `startRelink(for:)`'s
    /// `await` merely returns (that only covers token creation + presenting the sheet; see
    /// reservoir-1nn). `PlaidDebugLinkView` wires this to
    /// `TransactionImportService.refreshNeedsAttention()` so the Today-screen badge clears
    /// the moment relink succeeds, without needing another `runImport()` or app relaunch to
    /// re-sync it. A plain closure rather than a Combine publisher or a hard dependency on
    /// `TransactionImportService` — this class has no business knowing that type exists;
    /// the caller decides what "notify on relink success" means.
    var onRelinkSuccess: (() -> Void)?

    private let keychain: KeychainServicing
    private let urlSession: URLSession
    private let environmentStore: PlaidEnvironmentStoring
    private let cursorStore: PlaidSyncCursorStoring
    private let linkedItemStore: LinkedItemStoring

    /// The environment pinned for the Link flow currently in progress (set
    /// by `startLink()`, cleared once that flow settles). `createLinkToken()`
    /// and the matching `exchangePublicToken()` call in `handleLinkSuccess()`
    /// both read this rather than `environmentStore.current` independently —
    /// those two calls are separated by an async user interaction (the
    /// LinkKit sheet), so without pinning, a mid-flow environment flip could
    /// create the link token under one environment and exchange it against
    /// the other's host. `environmentStore.current` is still re-read fresh
    /// at the *start* of each new flow (`startLink()`), which is what gives
    /// reservoir-adq.6.2's "toggle takes effect on the next call without
    /// rebuild" — this only pins a flow already in progress, it doesn't
    /// change how the flag is read when no flow is running.
    private var pinnedEnvironment: PlaidEnvironment?
    private var environment: PlaidEnvironment { pinnedEnvironment ?? environmentStore.current }
    private var baseURL: URL { environment.baseURL }

    init(
        keychain: KeychainServicing = KeychainService(),
        urlSession: URLSession = .shared,
        environmentStore: PlaidEnvironmentStoring = PlaidEnvironmentStore(),
        cursorStore: PlaidSyncCursorStoring = PlaidSyncCursorStore(),
        linkedItemStore: LinkedItemStoring = LinkedItemStore()
    ) {
        self.keychain = keychain
        self.urlSession = urlSession
        self.environmentStore = environmentStore
        self.cursorStore = cursorStore
        self.linkedItemStore = linkedItemStore
        self.linkedItem = linkedItemStore.load()

        let keychainForInvalidation = keychain
        let cursorStoreForInvalidation = cursorStore
        let linkedItemStoreForInvalidation = linkedItemStore
        (environmentStore as? PlaidEnvironmentStore)?.onChange = { [weak self] _ in
            // Invalidate every sync cursor, not just the newly-selected environment's —
            // a stale cursor left behind for the environment being switched *away from*
            // would otherwise be reused unmodified the next time that environment is
            // switched back to, even though the linked item/Keychain token for it was
            // already cleared here (adq.6.3). One hook, one place — see
            // PlaidSyncCursorStore's doc comment / the plan's "Item 2" decision.
            for candidate in PlaidEnvironment.allCases {
                cursorStoreForInvalidation.clearCursor(for: candidate)
            }
            Task { @MainActor in
                self?.linkedItem = nil
                linkedItemStoreForInvalidation.clear()
                try? await keychainForInvalidation.delete(for: PlaidKeychainKey.accessToken)
            }
        }
    }

    func startLink() async {
        guard !isStartingLink else { return }
        isStartingLink = true
        defer { isStartingLink = false }

        // Pin the environment for the duration of this Link flow — read
        // fresh here (a new flow always picks up the latest toggle value,
        // per reservoir-adq.6.2), then held steady through
        // `handleLinkSuccess()`'s `exchangePublicToken()` call even if the
        // toggle changes while LinkKit's sheet is up. See `pinnedEnvironment`.
        pinnedEnvironment = environmentStore.current

        presentedError = nil
        do {
            let token = try await createLinkToken()
            linkToken = token
            linkSession = try makeSession(token: token)
            isPresentingLink = true
        } catch {
            presentedError = PlaidErrorClassifier.classify(.exchangeError(error))
            // Flow ended before Link ever presented — nothing left to pin for.
            pinnedEnvironment = nil
        }
    }

    /// The shared "Try again" affordance's action — retries whichever flow the last
    /// `presentedError` came from. Must stay relink-aware (reservoir-adq.6.5 code review):
    /// if a `startRelink(for:)` attempt fails (e.g. a transient network error creating the
    /// update-mode token) and the user taps "Try again", retrying via `startLink()` would
    /// silently create a brand-new item/token instead of repairing the existing one —
    /// exactly the bug the Relink button itself was fixed to avoid.
    func retry() async {
        presentedError = nil
        if let item = linkedItem {
            await startRelink(for: item)
        } else {
            await startLink()
        }
    }

    func handleLinkSuccess(publicToken: String, institutionName: String) async {
        isPresentingLink = false
        linkSession = nil
        isExchangingToken = true
        // This flow is settling one way or another below — release the pin
        // so the *next* flow picks up whatever environment is current then.
        defer {
            isExchangingToken = false
            pinnedEnvironment = nil
        }

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
        linkedItemStore.save(item)
    }

    func handleLinkExit(errorType: String?, errorCode: String?) {
        isPresentingLink = false
        linkSession = nil
        // Link exited without ever reaching handleLinkSuccess — this flow is
        // over, release the pin (see startLink()/pinnedEnvironment).
        pinnedEnvironment = nil
        guard errorType != nil || errorCode != nil else {
            // Plain user cancel — silent, no error UI (UX spec).
            return
        }
        presentedError = PlaidErrorClassifier.classify(
            .linkError(errorType: errorType, errorCode: errorCode)
        )
    }

    // MARK: - Update-mode relink (reservoir-adq.6.5)

    /// Re-authenticates `item` via Plaid's update-mode Link (a `link_token` scoped to the
    /// existing item's `access_token`, per `createRelinkToken(accessToken:)`) rather than
    /// creating a brand-new item/token. Mirrors `startLink()`'s shape (reentrancy guard,
    /// environment pinning, `presentedError` classification on failure) so
    /// `PlaidLinkPresentationView`'s existing `.sheet()` wiring works unchanged — the only
    /// difference is which token-creation call is made and, on success, which completion
    /// path runs (`handleRelinkSuccess()`, not `handleLinkSuccess(publicToken:institutionName:)`
    /// — no token re-exchange, since the access_token doesn't change in update mode).
    func startRelink(for item: LinkedItem) async {
        guard !isStartingLink else { return }
        isStartingLink = true
        defer { isStartingLink = false }

        pinnedEnvironment = environmentStore.current
        presentedError = nil

        guard let accessToken = try? await keychain.read(for: PlaidKeychainKey.accessToken) else {
            // No access token to relink — nothing Plaid-side has been attempted yet, so
            // this classifies the same generic way a pre-flight local failure would.
            // Not expected in normal use (a `LinkedItem` only ever exists because a token
            // was saved for it), but guards against an inconsistent Keychain/UserDefaults
            // state rather than crashing or silently no-oping.
            presentedError = PlaidErrorClassifier.classify(.exchangeError(URLError(.badServerResponse)))
            pinnedEnvironment = nil
            return
        }

        do {
            let token = try await createRelinkToken(accessToken: accessToken)
            linkToken = token
            linkSession = try makeSession(token: token, isRelink: true)
            isPresentingLink = true
        } catch {
            presentedError = PlaidErrorClassifier.classify(.exchangeError(error))
            pinnedEnvironment = nil
        }
    }

    /// Update-mode Link's `onSuccess` completion — clears `needsAttention` and nothing
    /// else. No `handleLinkSuccess`-style token exchange: Plaid's `access_token` doesn't
    /// change in update mode, so there is nothing new to persist to Keychain, and the
    /// `LinkedItem`'s `itemID`/`institutionName`/`linkedAt` are all unchanged too — only
    /// the flag this story added is ever touched here.
    func handleRelinkSuccess() {
        isPresentingLink = false
        linkSession = nil
        pinnedEnvironment = nil
        if var item = linkedItem {
            item.needsAttention = false
            linkedItem = item
            linkedItemStore.save(item)
        } else {
            linkedItemStore.setNeedsAttention(false)
        }
        // Notify after the flag is actually cleared (both in-memory and in the store) —
        // reservoir-1nn. This is the one point that genuinely marks relink completion;
        // startRelink(for:)'s own await returns far earlier, before the user has done
        // anything in the Link sheet.
        onRelinkSuccess?()
    }

    // MARK: - LinkKit session creation

    /// `isRelink` selects which completion path `onSuccess` runs — `handleRelinkSuccess()`
    /// (update mode) or `handleLinkSuccess(publicToken:institutionName:)` (a fresh Link).
    /// `onExit`'s error handling is identical either way (same `PlaidErrorClassifier`
    /// categories, same generic-error UX posture per this story's UX section), so it's
    /// shared rather than branched.
    private func makeSession(token: String, isRelink: Bool = false) throws -> PlaidLinkSession {
        let configuration = LinkTokenConfiguration(
            token: token,
            onSuccess: { [weak self] success in
                let publicToken = success.publicToken
                let institutionName = success.metadata.institution.name
                Task { @MainActor in
                    if isRelink {
                        self?.handleRelinkSuccess()
                    } else {
                        await self?.handleLinkSuccess(publicToken: publicToken, institutionName: institutionName)
                    }
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

    // MARK: - Plaid REST calls (direct from device, environment-aware)

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
            secret: PlaidCredentials.secret(
                for: environment,
                sandboxSecret: PlaidCredentials.sandboxSecret,
                productionSecret: PlaidCredentials.productionSecret
            ),
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

    /// Plaid's update-mode `/link/token/create` shape (reservoir-adq.6.5): includes the
    /// existing item's `access_token` and **omits `products` entirely** — both required by
    /// Plaid's own update-mode API contract, not this app's choice. `RequestBody` is a
    /// deliberately separate type from `createLinkToken()`'s (rather than one shared
    /// struct with an optional `access_token`/optional `products`) so a fresh Link request
    /// can never accidentally carry a stale `access_token`, and an update-mode request can
    /// never accidentally carry `products` — the type system enforces the two shapes stay
    /// distinct rather than relying on call-site discipline.
    private func createRelinkToken(accessToken: String) async throws -> String {
        struct RequestBody: Encodable {
            let client_id: String
            let secret: String
            let client_name: String
            let user: RequestUser
            let country_codes: [String]
            let language: String
            let redirect_uri: String
            let access_token: String

            struct RequestUser: Encodable { let client_user_id: String }
        }
        struct ResponseBody: Decodable { let link_token: String }

        let body = RequestBody(
            client_id: PlaidCredentials.clientID,
            secret: PlaidCredentials.secret(
                for: environment,
                sandboxSecret: PlaidCredentials.sandboxSecret,
                productionSecret: PlaidCredentials.productionSecret
            ),
            client_name: "Reservoir",
            user: .init(client_user_id: Self.clientUserID),
            country_codes: ["US"],
            language: "en",
            redirect_uri: PlaidOAuthRedirect.url.absoluteString,
            access_token: accessToken
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
            secret: PlaidCredentials.secret(
                for: environment,
                sandboxSecret: PlaidCredentials.sandboxSecret,
                productionSecret: PlaidCredentials.productionSecret
            ),
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

    // MARK: - client_user_id

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

    // Linked-item metadata persistence (institution name, item ID, linked date,
    // needsAttention) moved to `LinkedItemStore` (reservoir-adq.6.5) — this type now only
    // owns *when* to read/write it (init, a successful Link/relink, an environment
    // change), not the storage mechanism itself. See `linkedItemStore`'s doc comment.
}
