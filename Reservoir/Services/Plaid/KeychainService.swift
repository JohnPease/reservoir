import Foundation
import Security

/// Errors surfaced by `KeychainService`. Wraps the `Security` framework's
/// `OSStatus` codes so callers don't need to know Keychain internals.
enum KeychainError: Error, Equatable {
    /// A stored item existed but its data couldn't be decoded as a UTF-8 string.
    case unexpectedData
    /// `Security` returned a status this wrapper doesn't have a named case for.
    case unhandled(status: OSStatus)
}

/// Minimal wrapper around the `Security` framework's generic-password
/// Keychain APIs (`SecItemAdd`/`SecItemCopyMatching`/`SecItemUpdate`/
/// `SecItemDelete`). No third-party dependency — iOS ships no
/// SwiftData/Keychain bridge, so this is the idiomatic minimal approach
/// (see reservoir-adq.6.1's decisions log).
///
/// Items are stored with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`:
/// readable by background refresh triggers (reservoir-adq.6.4) after the
/// device has been unlocked once since boot, never iCloud-synced, never
/// exportable to another device.
///
/// `async`: the underlying `Security` calls are synchronous and can block
/// for a noticeable moment (device state, Keychain contention). Every call
/// site is `@MainActor` (`PlaidServiceLive`, `PlaidDebugLinkView`), so a
/// synchronous protocol here would block the main actor on every Keychain
/// touch — this `async` surface exists so `KeychainService`'s implementation
/// can hop off main, and so every future call site (reservoir-adq.6.4,
/// adq.6.5) inherits that off-main behavior for free rather than having to
/// remember to dispatch manually.
protocol KeychainServicing: Sendable {
    func save(_ value: String, for key: String) async throws
    func read(for key: String) async throws -> String?
    func delete(for key: String) async throws
}

struct KeychainService: KeychainServicing {
    /// `kSecAttrService` value items are namespaced under. Distinct values
    /// let tests use an isolated namespace instead of polluting/depending on
    /// whatever the app itself has stored.
    private let service: String

    init(service: String = "com.johnpease.Reservoir.plaid") {
        self.service = service
    }

    func save(_ value: String, for key: String) async throws {
        let service = service
        try await Self.offMainActor {
            try Self.performSave(value, for: key, service: service)
        }
    }

    func read(for key: String) async throws -> String? {
        let service = service
        return try await Self.offMainActor {
            try Self.performRead(for: key, service: service)
        }
    }

    func delete(for key: String) async throws {
        let service = service
        try await Self.offMainActor {
            try Self.performDelete(for: key, service: service)
        }
    }

    /// Runs a synchronous `Security`-framework call off the main actor.
    /// `Task.detached` is sufficient here (no shared mutable state to
    /// serialize against — each call builds its own query dictionary), and
    /// keeps this wrapper free of any custom `DispatchQueue`/executor
    /// plumbing.
    private static func offMainActor<T: Sendable>(
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await Task.detached(priority: .userInitiated) {
            try work()
        }.value
    }

    private static func performSave(_ value: String, for key: String, service: String) throws {
        let data = Data(value.utf8)
        let query = baseQuery(for: key, service: service)

        // Update-then-add: a plain SecItemAdd fails with errSecDuplicateItem
        // if a value is already stored for this key, so try to update the
        // existing item first and only add a new one if none exists yet.
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )

        if updateStatus == errSecSuccess {
            return
        }

        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.unhandled(status: updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unhandled(status: addStatus)
        }
    }

    private static func performRead(for key: String, service: String) throws -> String? {
        var query = baseQuery(for: key, service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let string = String(data: data, encoding: .utf8) else {
                throw KeychainError.unexpectedData
            }
            return string
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unhandled(status: status)
        }
    }

    private static func performDelete(for key: String, service: String) throws {
        let status = SecItemDelete(baseQuery(for: key, service: service) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandled(status: status)
        }
    }

    private static func baseQuery(for key: String, service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}
