import Foundation

/// Non-secret metadata for one Plaid account (checking, credit card, ...) under a linked
/// item (reservoir-j8t PR1). Captured from the top-level `accounts` array of
/// `/transactions/sync` responses; a plain value type so Budget UI (later PRs) and tests
/// never depend on the wire DTO or on `UserDefaults`.
struct LinkedAccount: Equatable, Codable, Sendable {
    let accountID: String
    let itemID: String
    var name: String
    var officialName: String?
    var mask: String?
    var type: String
    var subtype: String?
    var institutionName: String?

    /// Builds from the wire DTO. `type` falls back to `"other"` (Plaid's own catch-all
    /// account type) when absent so an odd payload never drops the account.
    init(_ account: PlaidAccount, itemID: String, institutionName: String?) {
        self.accountID = account.account_id
        self.itemID = itemID
        self.name = account.name
        self.officialName = account.official_name
        self.mask = account.mask
        self.type = account.type ?? "other"
        self.subtype = account.subtype
        self.institutionName = institutionName
    }

    init(
        accountID: String,
        itemID: String,
        name: String,
        officialName: String? = nil,
        mask: String? = nil,
        type: String,
        subtype: String? = nil,
        institutionName: String? = nil
    ) {
        self.accountID = accountID
        self.itemID = itemID
        self.name = name
        self.officialName = officialName
        self.mask = mask
        self.type = type
        self.subtype = subtype
        self.institutionName = institutionName
    }

    /// `update` wins for every field it provides; optional fields it omits keep this
    /// value's (a later page may list the same account with less detail).
    func merged(with update: LinkedAccount) -> LinkedAccount {
        LinkedAccount(
            accountID: accountID,
            itemID: update.itemID,
            name: update.name,
            officialName: update.officialName ?? officialName,
            mask: update.mask ?? mask,
            type: update.type,
            subtype: update.subtype ?? subtype,
            institutionName: update.institutionName ?? institutionName
        )
    }

    /// Upserts `incoming` into `existing` keyed by `accountID`. Accounts absent from
    /// `incoming` are **never** removed: each `/transactions/sync` page lists only the
    /// accounts its own transactions reference, and a no-change sync returns an empty
    /// array, so absence carries no information.
    static func upserting(_ incoming: [LinkedAccount], into existing: [LinkedAccount]) -> [LinkedAccount] {
        var result = existing
        for account in incoming {
            if let index = result.firstIndex(where: { $0.accountID == account.accountID }) {
                result[index] = result[index].merged(with: account)
            } else {
                result.append(account)
            }
        }
        return result
    }
}

/// Persists `LinkedAccount`s, same `UserDefaults`-JSON pattern and protocol-for-tests
/// reasoning as `LinkedItemStoring`. Accounts are keyed by `accountID` and scoped to an
/// item; there is no environment dimension because an item (and so its accounts) is
/// only ever valid for the environment it was linked under, and everything is removed on
/// an environment change.
protocol LinkedAccountStoring: Sendable {
    func loadAll() -> [LinkedAccount]
    /// Upsert-merge; never deletes anything (see `LinkedAccount.upserting`). An empty
    /// array is a no-op.
    func upsert(_ accounts: [LinkedAccount])
    /// Removes every account belonging to `itemID` — on unlink and on environment change.
    func removeAll(itemID: String)
}

extension LinkedAccountStoring {
    func accounts(itemID: String) -> [LinkedAccount] {
        loadAll().filter { $0.itemID == itemID }
    }
}

final class LinkedAccountStore: LinkedAccountStoring, @unchecked Sendable {
    private static let defaultsKey = "plaid.linkedAccounts"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadAll() -> [LinkedAccount] {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([LinkedAccount].self, from: data)) ?? []
    }

    func upsert(_ accounts: [LinkedAccount]) {
        guard !accounts.isEmpty else { return }
        persist(LinkedAccount.upserting(accounts, into: loadAll()))
    }

    func removeAll(itemID: String) {
        var accounts = loadAll()
        accounts.removeAll { $0.itemID == itemID }
        persist(accounts)
    }

    private func persist(_ accounts: [LinkedAccount]) {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
