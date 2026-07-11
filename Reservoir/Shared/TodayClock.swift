import SwiftUI

/// The app's single shared "now" — kept current by one `ReferenceDateKeeper` applied once
/// at `RootTabView`, and read by every screen that needs a reference date (`TodayView`,
/// `GoalsView`) via `@Environment(TodayClock.self)`.
///
/// Previously `TodayView` and `GoalsView` each held their own `@State private var
/// referenceDate` and independently applied `.keepingReferenceDateCurrent(...)`, which
/// meant two concurrent long-lived midnight-sleep `Task`s plus two `scenePhase` observers
/// for the app's lifetime (since `TabView` keeps both tabs' content mounted once visited)
/// — both redundantly computing the same day-rollover event. Consolidated to one
/// `TodayClock` instance, refreshed by exactly one `ReferenceDateKeeper` (STANDARDS.md
/// §3 — no duplicated logic).
@Observable
final class TodayClock {
    var referenceDate: Date = .now
}
