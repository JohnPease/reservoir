import Foundation

/// Where each credit card's statement closes and its bill falls due (reservoir-17g), entered by
/// the user per linked account. Kept in `UserDefaults` beside `LinkedAccountStore`, whose account
/// metadata also lives outside SwiftData, so no schema migration is needed.
struct CardCycleSettings: Equatable, Codable {
    var closingDay: Int?
    var dueDay: Int?
}

final class CardCycleStore: @unchecked Sendable {
    private static let defaultsKey = "card.cycleSettings"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadAll() -> [String: CardCycleSettings] {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return [:] }
        return (try? JSONDecoder().decode([String: CardCycleSettings].self, from: data)) ?? [:]
    }

    func save(_ settings: CardCycleSettings, accountID: String) {
        var all = loadAll()
        all[accountID] = settings
        if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: Self.defaultsKey) }
    }

    func clear() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }
}
