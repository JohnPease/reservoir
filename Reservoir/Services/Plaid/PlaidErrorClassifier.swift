import Foundation

/// User-facing bucket for a Plaid Link or token-exchange failure. Deliberately
/// coarse — the target user isn't financially/technically sophisticated (see
/// PROJECT_SPEC.md), so raw Plaid `errorCode`/`errorType` strings are never
/// surfaced; only this classification drives on-screen copy. User-cancelled
/// Link sessions are not a case here — they're handled as a silent, non-error
/// exit by the caller before this classifier is ever consulted.
enum PlaidErrorCategory: Equatable {
    /// No connectivity, or the request to Plaid timed out — a local/network
    /// condition rather than something Plaid's servers did. Only reachable
    /// from `.exchangeError`: LinkKit's `onExit` taxonomy (`.linkError`) has
    /// no client-connectivity category, so `.linkError` never classifies as
    /// `.network` — see `PlaidErrorClassifier.classify`.
    case network
    /// Plaid's servers (or the linked institution) returned an error —
    /// invalid credentials, institution outage, API-level failure, etc.
    case plaidSide
}

/// Input to `PlaidErrorClassifier`, shaped to keep the classifier free of any
/// `LinkKit` dependency (STANDARDS §4: Plaid SDK types must not leak past
/// `PlaidService`). Callers map LinkKit's `PlaidError` (from `onExit`) or a
/// thrown `Error` from the direct-from-device token-exchange call into one of
/// these cases before calling `classify`.
enum PlaidFailureInput {
    /// A `PlaidError` reported by LinkKit's `onExit`, reduced to its two
    /// identifying strings. Always classifies as `.plaidSide` (see
    /// `PlaidErrorClassifier.classify`) — the strings are carried here for
    /// logging/debugging and for reservoir-adq.6.5's reuse of this type, not
    /// because `classify` inspects them today.
    case linkError(errorType: String?, errorCode: String?)
    /// A `URLSession`/`Codable` failure from the app's own direct call to
    /// Plaid's `/item/public_token/exchange` endpoint.
    case exchangeError(Error)
}

/// Pure function mapping a Plaid Link or token-exchange failure into a
/// `PlaidErrorCategory`. No I/O, no LinkKit dependency — reused as-is by
/// reservoir-adq.6.5 for classifying `ITEM_LOGIN_REQUIRED`-style import-time
/// errors on an already-linked item, so keep this generically named and
/// free of anything specific to the initial-link flow.
enum PlaidErrorClassifier {
    static func classify(_ input: PlaidFailureInput) -> PlaidErrorCategory {
        switch input {
        case .linkError:
            // LinkKit's onExit error taxonomy (ExitErrorCode: apiError,
            // authError, assetReportError, internal, institutionError,
            // itemError, invalidInput, invalidRequest, rateLimitExceeded,
            // unknown — see PlaidServiceLive.errorType(for:)) is exclusively
            // Plaid/institution-side; verified against LinkKit 7.0.2's public
            // interface, there is no client-connectivity category. LinkKit's
            // own webview handles offline/timeout conditions internally
            // rather than surfacing them through onExit, so a genuine local
            // network failure during the Link flow never reaches this
            // classifier as a .linkError in the first place. Every
            // .linkError is therefore .plaidSide, unconditionally.
            return .plaidSide

        case .exchangeError(let error):
            if let urlError = error as? URLError {
                return Self.isNetworkURLError(urlError) ? .network : .plaidSide
            }
            // Non-URLError failures from the exchange call (malformed JSON,
            // an HTTP error status Plaid returned, etc.) are Plaid's servers
            // responding, not a local connectivity problem.
            return .plaidSide
        }
    }

    private static func isNetworkURLError(_ error: URLError) -> Bool {
        switch error.code {
        case .notConnectedToInternet,
             .networkConnectionLost,
             .timedOut,
             .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed,
             .internationalRoamingOff,
             .dataNotAllowed,
             .secureConnectionFailed:
            return true
        default:
            return false
        }
    }
}

extension PlaidErrorCategory {
    /// The exact copy the UX spec locks in for this category (reservoir-adq.6.1
    /// UX section). Centralized here so the two-bucket copy can't drift
    /// between the initial-link flow and adq.6.5's relink flow, which reuses
    /// this same classifier.
    var userFacingMessage: String {
        switch self {
        case .network:
            return "Couldn't reach the network. Check your connection and try again."
        case .plaidSide:
            return "Couldn't connect to your bank. Try again."
        }
    }
}
