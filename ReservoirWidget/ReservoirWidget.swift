import SwiftUI
import WidgetKit

/// One timeline entry: the planner's phase applied to the stored snapshot, already
/// resolved into what to draw.
struct ReservoirEntry: TimelineEntry {
    let date: Date
    let presentation: WidgetPresentation
}

struct ReservoirTimelineProvider: TimelineProvider {
    var store: WidgetSnapshotStoring = FileWidgetSnapshotStore.appGroup()
    var calendar: Calendar = .current

    func placeholder(in context: Context) -> ReservoirEntry {
        sampleEntry(now: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (ReservoirEntry) -> Void) {
        if context.isPreview {
            completion(sampleEntry(now: .now))
            return
        }
        completion(timelineEntries(now: .now).first ?? sampleEntry(now: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ReservoirEntry>) -> Void) {
        let now = Date.now
        let entries = timelineEntries(now: now)
        // The last planned entry is the terminal "refresh" (or set-up) state; check back
        // occasionally in case the app wrote a new snapshot without a reload reaching us.
        let policyDate = (entries.last?.date ?? now).addingTimeInterval(6 * 3600)
        completion(Timeline(entries: entries, policy: .after(policyDate)))
    }

    private func timelineEntries(now: Date) -> [ReservoirEntry] {
        guard let snapshot = store.load() else {
            return [ReservoirEntry(
                date: now,
                presentation: .make(snapshot: nil, phase: .current, showsUpdatedCaption: false)
            )]
        }
        return WidgetTimelinePlanner.entries(generatedAt: snapshot.generatedAt, now: now, calendar: calendar)
            .map { plan in
                ReservoirEntry(
                    date: plan.date,
                    presentation: .make(
                        snapshot: snapshot, phase: plan.phase, showsUpdatedCaption: plan.showsUpdatedCaption
                    )
                )
            }
    }

    private func sampleEntry(now: Date) -> ReservoirEntry {
        ReservoirEntry(
            date: now,
            presentation: .make(snapshot: .sample(now: now, calendar: calendar), phase: .current, showsUpdatedCaption: false)
        )
    }
}

struct ReservoirWidget: Widget {
    let kind = "ReservoirWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ReservoirTimelineProvider()) { entry in
            ReservoirWidgetView(entry: entry)
                .widgetURL(WidgetDeepLink.todayURL)
        }
        .configurationDisplayName("Left today")
        .description("What is left to spend today.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

#Preview("Small", as: .systemSmall) {
    ReservoirWidget()
} timeline: {
    ReservoirEntry(date: .now, presentation: .make(snapshot: .sample(), phase: .current, showsUpdatedCaption: false))
    ReservoirEntry(date: .now, presentation: .make(snapshot: .sample(), phase: .estimate, showsUpdatedCaption: false))
}

#Preview("Medium", as: .systemMedium) {
    ReservoirWidget()
} timeline: {
    ReservoirEntry(date: .now, presentation: .make(snapshot: .sample(), phase: .current, showsUpdatedCaption: true))
}

#Preview("Lock screen", as: .accessoryRectangular) {
    ReservoirWidget()
} timeline: {
    ReservoirEntry(date: .now, presentation: .make(snapshot: .sample(), phase: .current, showsUpdatedCaption: false))
}
