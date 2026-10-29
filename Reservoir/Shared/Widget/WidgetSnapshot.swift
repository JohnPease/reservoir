import Foundation

/// The app-written, widget-read summary of today's spending figures. A plain value type
/// with no identifiers, merchant names, or account details — only the handful of
/// numbers and strings the widget draws — so that the App Group file holds nothing
/// sensitive beyond amounts. The widget never computes; it renders this (the calculators
/// stay in the app target).
///
/// Two sets of figures are stored: `today` (as of `generatedAt`) and `tomorrow` (the same
/// calculators evaluated at the start of the next day, nothing more spent), so that after
/// midnight the widget can show an honest, labeled estimate without the app running.
struct WidgetSnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int = WidgetSnapshot.currentVersion
    var generatedAt: Date
    var today: Figures
    /// Start of the day `tomorrow` describes (the local midnight after `generatedAt`).
    var tomorrowStart: Date
    var tomorrow: Figures

    /// Everything the widget shows for one reference day.
    struct Figures: Codable, Equatable, Sendable {
        var budget: Section
        var savings: Section
        /// Only present for an active budget; powers the medium widget's right half when
        /// there is no savings goal.
        var month: MonthProgress?
    }

    /// One daily-limit tracker (the monthly budget, or the savings-goal limit).
    struct Section: Codable, Equatable, Sendable {
        enum State: String, Codable, Sendable {
            case active
            /// Budget only: account backfill still running.
            case syncing
            /// Budget only: a budget exists with no accounts selected.
            case chooseAccounts
            /// No budget / no active savings goal.
            case notSet
        }

        var state: State
        /// Present only when `state == .active`.
        var remaining: Decimal?
        var limit: Decimal?
        var spentToday: Decimal?

        static let notSet = Section(state: .notSet)
        static func message(_ state: State) -> Section { Section(state: state) }
        static func active(remaining: Decimal, limit: Decimal, spentToday: Decimal) -> Section {
            Section(state: .active, remaining: remaining, limit: limit, spentToday: spentToday)
        }
    }

    struct MonthProgress: Codable, Equatable, Sendable {
        var monthName: String
        /// `BudgetSummaryCalculator`'s progress sentence, verbatim.
        var sentence: String
        var spent: Decimal
        var monthlyAmount: Decimal
    }

    /// Equality ignoring `generatedAt`: "did the numbers change".
    func hasSameFigures(as other: WidgetSnapshot) -> Bool {
        version == other.version
            && today == other.today
            && tomorrowStart == other.tomorrowStart
            && tomorrow == other.tomorrow
    }
}

extension WidgetSnapshot {
    /// Illustrative data for the widget gallery and previews only.
    static func sample(now: Date = .now, calendar: Calendar = .current) -> WidgetSnapshot {
        let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        let figures = Figures(
            budget: .active(remaining: 38.20, limit: 52.40, spentToday: 14.20),
            savings: .active(remaining: 24.10, limit: 30, spentToday: 5.90),
            month: MonthProgress(
                monthName: "October",
                sentence: "On pace. $214 under your pace so far.",
                spent: 1126,
                monthlyAmount: 1860
            )
        )
        return WidgetSnapshot(generatedAt: now, today: figures, tomorrowStart: tomorrowStart, tomorrow: figures)
    }
}
