import SwiftUI

/// Pure date math backing `ReferenceDateKeeper`'s midnight-boundary refresh — split out
/// so it's unit-testable without driving a live `Task`/SwiftUI environment (STANDARDS.md
/// §3).
enum ReferenceDateScheduling {
    /// The next midnight (device-local calendar day boundary) strictly after `date`.
    /// Falls back to `date + 24h` in the practically-unreachable case where
    /// `calendar.nextDate` can't resolve a match.
    static func nextMidnight(after date: Date, calendar: Calendar) -> Date {
        calendar.nextDate(
            after: date,
            matching: DateComponents(hour: 0, minute: 0, second: 0),
            matchingPolicy: .nextTime
        ) ?? date.addingTimeInterval(86_400)
    }
}

/// Keeps a `referenceDate` binding current: refreshed on first appearance, on
/// `scenePhase` transitioning to `.active` (foreground resume), and at each midnight
/// boundary via a long-lived `.task` — so a session left open overnight still rolls the
/// daily limit / goal lifecycle over without requiring a foreground-resume event.
///
/// Originally lived only in `TodayView` as `scheduleMidnightRefresh()`; `GoalsView`
/// refreshed on `.onAppear` alone and went stale for the scenePhase/midnight cases
/// (code-review finding on PR #5). Extracted here as the one shared implementation both
/// views apply via `View.keepingReferenceDateCurrent(_:calendar:)` rather than each
/// declaring its own near-identical `Task` loop (STANDARDS.md §3 — no copy-paste).
struct ReferenceDateKeeper: ViewModifier {
    @Binding var referenceDate: Date
    @Environment(\.scenePhase) private var scenePhase
    let calendar: Calendar

    func body(content: Content) -> some View {
        content
            .onAppear { referenceDate = .now }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active { referenceDate = .now }
            }
            .task { await scheduleMidnightRefresh() }
    }

    private func scheduleMidnightRefresh() async {
        while !Task.isCancelled {
            let now = Date()
            let nextMidnight = ReferenceDateScheduling.nextMidnight(after: now, calendar: calendar)

            let nanoseconds = UInt64(max(nextMidnight.timeIntervalSince(now), 1)) * 1_000_000_000
            try? await Task.sleep(nanoseconds: nanoseconds)

            guard !Task.isCancelled else { return }
            referenceDate = .now
        }
    }
}

extension View {
    /// Applies `ReferenceDateKeeper` to keep `referenceDate` current — see its doc
    /// comment for the exact refresh triggers.
    func keepingReferenceDateCurrent(_ referenceDate: Binding<Date>, calendar: Calendar = .current) -> some View {
        modifier(ReferenceDateKeeper(referenceDate: referenceDate, calendar: calendar))
    }
}
