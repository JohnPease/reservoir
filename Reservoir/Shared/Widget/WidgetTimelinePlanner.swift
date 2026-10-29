import Foundation

/// What a widget entry should show relative to the snapshot's age.
enum WidgetPhase: Equatable, Sendable {
    /// Same local day as the snapshot and younger than the staleness limit.
    case current
    /// The next local day: show the snapshot's "tomorrow" figures, labeled as an estimate.
    case estimate
    /// Too old to trust: ask the user to open the app.
    case needsRefresh
}

/// One planned timeline entry (the widget turns it into a `TimelineEntry`).
struct WidgetEntryPlan: Equatable, Sendable {
    var date: Date
    var phase: WidgetPhase
    /// True once the data is older than `WidgetTimelinePlanner.captionAfter` (small and
    /// medium widgets then show "Updated <time>").
    var showsUpdatedCaption: Bool
}

/// Pure planning of the widget's timeline, so the day-rollover / staleness rules are
/// unit-testable without WidgetKit. Calendar arithmetic only (no fixed 86 400 s days) so
/// DST transitions land on the right local midnight.
enum WidgetTimelinePlanner {
    static let staleAfter: TimeInterval = 36 * 3600
    static let captionAfter: TimeInterval = 3 * 3600

    static func phase(generatedAt: Date, at date: Date, calendar: Calendar) -> WidgetPhase {
        let age = date.timeIntervalSince(generatedAt)
        guard age >= 0 else { return .current }
        if age >= staleAfter { return .needsRefresh }
        switch dayOffset(from: generatedAt, to: date, calendar: calendar) {
        case ...0: return .current
        case 1: return .estimate
        default: return .needsRefresh
        }
    }

    static func showsUpdatedCaption(generatedAt: Date, at date: Date) -> Bool {
        date.timeIntervalSince(generatedAt) >= captionAfter
    }

    /// Entries starting with one for `now`, then one at every future moment the display
    /// changes: caption threshold, local midnight (estimate), the midnight after that and
    /// the 36-hour mark (refresh).
    static func entries(generatedAt: Date, now: Date, calendar: Calendar) -> [WidgetEntryPlan] {
        let snapshotDay = calendar.startOfDay(for: generatedAt)
        var boundaries: [Date] = [generatedAt.addingTimeInterval(captionAfter)]
        for dayCount in 1...2 {
            if let midnight = calendar.date(byAdding: .day, value: dayCount, to: snapshotDay) {
                boundaries.append(midnight)
            }
        }
        boundaries.append(generatedAt.addingTimeInterval(staleAfter))

        let future = Set(boundaries.filter { $0 > now }).sorted()
        return ([now] + future).map { date in
            WidgetEntryPlan(
                date: date,
                phase: phase(generatedAt: generatedAt, at: date, calendar: calendar),
                showsUpdatedCaption: showsUpdatedCaption(generatedAt: generatedAt, at: date)
            )
        }
    }

    private static func dayOffset(from start: Date, to end: Date, calendar: Calendar) -> Int {
        calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: end)
        ).day ?? 0
    }
}
