import Foundation

/// Persistence for budget warning notifications (reservoir-nka.3): the Settings toggle and the
/// highest level already handled this month. Only `BudgetWarningNotifier` writes the record.
protocol BudgetWarningNotificationStoring: AnyObject {
    var isEnabled: Bool { get set }
    func loadRecord() -> BudgetWarningNotificationRecord?
    func saveRecord(_ record: BudgetWarningNotificationRecord)
    func clearRecord()
}

/// `UserDefaults`-backed store. A corrupt record loads as `nil`, which the planner treats as
/// "no record" (a silent baseline), the safe direction.
final class BudgetWarningNotificationStore: BudgetWarningNotificationStoring {
    static let enabledKey = "budgetWarnings.enabled"
    static let recordKey = "budgetWarnings.notifiedRecord.v1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isEnabled: Bool {
        get { defaults.bool(forKey: Self.enabledKey) }
        set { defaults.set(newValue, forKey: Self.enabledKey) }
    }

    func loadRecord() -> BudgetWarningNotificationRecord? {
        guard let data = defaults.data(forKey: Self.recordKey) else { return nil }
        return try? JSONDecoder().decode(BudgetWarningNotificationRecord.self, from: data)
    }

    func saveRecord(_ record: BudgetWarningNotificationRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: Self.recordKey)
    }

    func clearRecord() {
        defaults.removeObject(forKey: Self.recordKey)
    }

    /// Removes both keys (UI-test reset).
    static func resetAll(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: enabledKey)
        defaults.removeObject(forKey: recordKey)
    }
}
