import Foundation
import Observation

/// A successfully linked Plaid item, reduced to the minimal metadata the
/// rest of the app needs. Plain struct, not a SwiftData `@Model` — this
/// story only needs to prove Link + exchange + Keychain storage work
/// end to end. Where linked-item metadata is queried for real UI (Settings'
/// account list, reservoir-adq.7) may need a SwiftData schema decision at
/// that point; that's flagged forward, not resolved here (see
/// reservoir-adq.6.1's Technical approach).
struct LinkedItem: Equatable, Sendable {
    let itemID: String
    let institutionName: String
    let linkedAt: Date
    /// True whenever the most recent import attempt against this item returned a
    /// genuine item-level auth error (`ITEM_LOGIN_REQUIRED`, most commonly) —
    /// reservoir-adq.6.5. Defaults to `false` so every existing call site
    /// constructing a `LinkedItem` for a fresh successful Link (this file's own
    /// `handleLinkSuccess`, plus test fixtures) keeps compiling unchanged. Cleared by a
    /// successful update-mode relink (`PlaidServiceLive.startRelink(for:)`), set by
    /// `TransactionImportService` when it classifies an import failure as
    /// `.itemLoginRequired` — both read/write this exclusively through
    /// `LinkedItemStoring`, never a second parallel mechanism.
    var needsAttention: Bool = false
}

/// Keychain key the single linked item's access token is stored under.
/// One linked item / one Keychain entry for this story — multi-account
/// linking is explicitly out of scope (reservoir-adq.6.1's Out of scope).
enum PlaidKeychainKey {
    static let accessToken = "plaid.accessToken"
}

/// App-domain owner of the Plaid Link session lifecycle and token exchange.
/// This is the sole point where `import LinkKit` may appear, aside from the
/// Link-presentation view itself (STANDARDS §4 / reservoir-adq.6.1's
/// acceptance criteria) — no `LinkKit` type appears anywhere in this
/// protocol's public surface. Views and business-logic code depend on this
/// protocol, never on `LinkKit` directly.
@MainActor
protocol PlaidService: AnyObject {
    /// Whether the Link presentation view should currently be shown.
    /// Set to `true` by `startLink()` once a link token is ready; the
    /// Link-presentation view binds to this and flips it back to `false`
    /// on any exit.
    var isPresentingLink: Bool { get set }

    /// The Link token most recently fetched for the pending session, or nil
    /// if none has been fetched yet / the last session finished.
    var linkToken: String? { get }

    /// True while the public-token → access-token exchange call is in
    /// flight. Drives the inline spinner the UX spec requires so the
    /// network call never appears to hang with no feedback.
    var isExchangingToken: Bool { get }

    /// The most recently linked item, if any exchange has succeeded and
    /// been stored in Keychain this session or on a prior launch.
    var linkedItem: LinkedItem? { get }

    /// User-facing error to display, or nil. Set by `handleLinkExit` and by
    /// a failed exchange; cleared when the user dismisses it or retries.
    var presentedError: PlaidErrorCategory? { get set }

    /// Fetches a Link token from Plaid and flips `isPresentingLink` to
    /// `true` once ready. A network/Plaid-side failure fetching the token
    /// itself is classified and surfaced via `presentedError`, same as any
    /// other failure in this flow.
    func startLink() async

    /// Called by the Link-presentation view's `onSuccess` callback with the
    /// data it extracted from LinkKit's `LinkSuccess` metadata. Exchanges
    /// the public token for an access token and persists it to Keychain.
    func handleLinkSuccess(publicToken: String, institutionName: String) async

    /// Called by the Link-presentation view's `onExit` callback. `errorType`/
    /// `errorCode` are nil for a plain user cancel (silent, no error UI);
    /// non-nil values are run through `PlaidErrorClassifier` and populate
    /// `presentedError`.
    func handleLinkExit(errorType: String?, errorCode: String?)

    /// Clears `presentedError` and re-opens Link — the single "Try again"
    /// affordance the UX spec calls for.
    func retry() async

    /// Fetches a Link token scoped to `item`'s existing `access_token` (Plaid's "update
    /// mode" — reservoir-adq.6.5) and flips `isPresentingLink` to `true` once ready, same
    /// as `startLink()`. Used to re-authenticate an already-linked item (most commonly
    /// after `ITEM_LOGIN_REQUIRED`) without creating a duplicate item/token. On success,
    /// clears the item's `needsAttention` flag — no token re-exchange is needed, since
    /// Plaid's `access_token` doesn't change in update mode. A failure fetching the
    /// update-mode token, or a LinkKit exit error during the update-mode session, is
    /// classified and surfaced via `presentedError`, same generic-error posture as
    /// `startLink()`.
    func startRelink(for item: LinkedItem) async
}
