import Foundation

/// A calendar month as plain integers, so the once-per-month record survives time zone and
/// calendar changes (it is compared by value, never as an instant).
struct BudgetWarningMonth: Codable, Equatable {
    var year: Int
    var month: Int

    init(year: Int, month: Int) {
        self.year = year
        self.month = month
    }

    init(containing date: Date, calendar: Calendar) {
        let parts = calendar.dateComponents([.year, .month], from: date)
        self.init(year: parts.year ?? 0, month: parts.month ?? 0)
    }

    /// `yyyy-MM`, used in the notification identifier.
    var key: String { String(format: "%04d-%02d", year, month) }
}

/// The highest warning level already handled (notified or silently baselined) for a month.
struct BudgetWarningNotificationRecord: Codable, Equatable {
    var month: BudgetWarningMonth
    var level: BudgetWarningLevel
}

/// The slice of `UNAuthorizationStatus` the planner cares about, without importing
/// UserNotifications into pure logic.
enum NotificationAuthorization: Equatable {
    case notDetermined, denied, authorized, provisional, ephemeral

    var allowsDelivery: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral: return true
        case .notDetermined, .denied: return false
        }
    }
}

/// What gets posted. Deliberately generic (no amounts, no dates): a notification can show on a
/// locked screen.
struct BudgetWarningNotificationContent: Equatable {
    var title: String
    var body: String
    /// One per month, so a later level replaces the earlier banner and Notification Center
    /// keeps a single entry.
    var identifier: String
    var threadIdentifier: String
    var deepLink: URL
}

/// Pure decision logic for budget warning notifications (reservoir-nka.3). Given the current
/// recovery result and what was already handled this month, says whether to post, record
/// silently, clear the record, or do nothing. No I/O; `BudgetWarningNotifier` applies it.
enum BudgetWarningNotificationPlanner {
    /// Levels below this are recorded but never notified.
    static let minimumNotifiedLevel: BudgetWarningLevel = .hardToRecover
    static let threadIdentifier = "budget-warnings"
    static let body = "Tap to see where you stand."
    static let deepLink = URL(string: "reservoir://today")!

    struct Input {
        var isEnabled: Bool
        var authorization: NotificationAuthorization
        var isAccountBackfillComplete: Bool
        /// `nil` when there is no budget or the card isn't active.
        var result: BudgetRecoveryCalculator.Result?
        var record: BudgetWarningNotificationRecord?
        var calendar: Calendar
    }

    enum Decision: Equatable {
        case nothing
        case clearRecord
        case saveRecord(BudgetWarningNotificationRecord)
        case notify(BudgetWarningNotificationRecord, BudgetWarningNotificationContent)
    }

    /// First matching rule wins:
    /// 1. disabled: nothing.
    /// 2. notification permission not granted: nothing (nothing recorded either, so a later
    ///    grant baselines silently rather than announcing old news).
    /// 3. account backfill incomplete: the figures can't be trusted, never notify; drop any
    ///    record so the next trustworthy evaluation starts clean.
    /// 4. no result (no budget / card inactive): nothing; the record is kept, so a budget that
    ///    is briefly unavailable doesn't re-announce a level it already announced.
    /// 5. no record: record the current level silently, even at a warning level (a budget
    ///    first created or first observed mid-month at a warning level is baseline, not news).
    /// 6. record is for another month: it counts as `.none`; notify if the level is notifiable,
    ///    else record silently.
    /// 7. same month, level rose to a notifiable level: notify.
    /// 8. same month, level rose below the notifiable level: record silently.
    /// 9. same month, level did not rise: nothing (a dip and re-rise stays silent).
    static func decide(_ input: Input) -> Decision {
        guard input.isEnabled else { return .nothing }
        guard input.authorization.allowsDelivery else { return .nothing }
        guard input.isAccountBackfillComplete else {
            return input.record == nil ? .nothing : .clearRecord
        }
        guard let result = input.result else { return .nothing }

        let month = BudgetWarningMonth(containing: result.monthStart, calendar: input.calendar)
        let level = result.warning.level
        let current = BudgetWarningNotificationRecord(month: month, level: level)

        guard let record = input.record else { return .saveRecord(current) }

        let recordedLevel: BudgetWarningLevel = record.month == month ? record.level : .none
        guard level > recordedLevel else {
            // Rolled over to a month that starts calm, or the level did not rise.
            return record.month == month ? .nothing : .saveRecord(current)
        }
        if level >= minimumNotifiedLevel, let content = content(for: level, month: month) {
            return .notify(current, content)
        }
        return .saveRecord(current)
    }

    /// `nil` below `minimumNotifiedLevel`.
    static func content(for level: BudgetWarningLevel, month: BudgetWarningMonth) -> BudgetWarningNotificationContent? {
        guard level >= minimumNotifiedLevel, let status = BudgetRecoveryCalculator.status(level) else { return nil }
        return BudgetWarningNotificationContent(
            title: "\(status) this month",
            body: body,
            identifier: "budget-warning.\(month.key)",
            threadIdentifier: threadIdentifier,
            deepLink: deepLink
        )
    }
}
