import Foundation

/// Which Plaid credential set / API host `PlaidServiceLive` should use.
/// Not a secret itself — just a mode selector — so it is persisted via
/// `UserDefaults` (through `PlaidEnvironmentStore`), never Keychain.
/// Switching is a runtime toggle, not a build configuration, per
/// reservoir-adq.6.2's amendment to `docs/PROJECT_SPEC.md`.
enum PlaidEnvironment: String, CaseIterable, Sendable {
    case sandbox
    case production

    /// Plaid's REST API host for this environment.
    var baseURL: URL {
        switch self {
        case .sandbox: URL(string: "https://sandbox.plaid.com")!
        case .production: URL(string: "https://production.plaid.com")!
        }
    }

    var displayName: String {
        switch self {
        case .sandbox: "Sandbox"
        case .production: "Production"
        }
    }
}

/// Persists the user's chosen `PlaidEnvironment` across launches.
/// `UserDefaults`-backed, consistent with this app's other non-financial,
/// non-secret app-wide settings (see `PlaidServiceLive`'s `clientUserID`/
/// linked-item persistence and PROJECT_SPEC's "no `User` entity" note).
/// A protocol so `PlaidServiceLive` and its tests don't depend on
/// `UserDefaults` directly.
protocol PlaidEnvironmentStoring: Sendable {
    var current: PlaidEnvironment { get }
    func set(_ environment: PlaidEnvironment)
}

final class PlaidEnvironmentStore: PlaidEnvironmentStoring, @unchecked Sendable {
    private static let defaultsKey = "plaid.environment"
    private let defaults: UserDefaults

    /// Fired whenever `set(_:)` actually changes the persisted environment
    /// (not called on a no-op set to the same value). A linked item /
    /// Keychain access token is only ever valid for the environment it was
    /// linked under — given this story's "one linked item for now" design,
    /// the simplest correct handling is to invalidate that state on a real
    /// environment change rather than carry it forward incorrectly (code
    /// review finding on PR #12: linked-item/Keychain state wasn't scoped
    /// by environment, so switching Sandbox -> Production left the UI
    /// showing the Sandbox-linked item as if it were Production state).
    /// `@Sendable` since `set(_:)` isn't actor-isolated; the one real
    /// listener (`PlaidServiceLive`) hops back to `@MainActor` itself.
    var onChange: (@Sendable (PlaidEnvironment) -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var current: PlaidEnvironment {
        defaults.string(forKey: Self.defaultsKey).flatMap(PlaidEnvironment.init(rawValue:)) ?? .sandbox
    }

    func set(_ environment: PlaidEnvironment) {
        let previous = current
        defaults.set(environment.rawValue, forKey: Self.defaultsKey)
        guard environment != previous else { return }
        onChange?(environment)
    }
}
