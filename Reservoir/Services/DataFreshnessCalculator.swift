import Foundation

/// The "how current is the imported data" line (reservoir-3oe). Chase data reaches the app
/// about a day late, so the app says when it last synced and the date of the newest
/// imported charge. Pure; no SwiftData or SwiftUI.
enum DataFreshnessCalculator {
    /// `nil` when there is nothing to say (no sync recorded and no imported charge), so
    /// manual-only users never see the line.
    static func text(
        lastSync: Date?,
        newestImportedDate: Date?,
        now: Date,
        calendar: Calendar = .current
    ) -> String? {
        var parts: [String] = []
        let timeStyle = Date.FormatStyle(date: .omitted, time: .shortened, calendar: calendar, timeZone: calendar.timeZone)
        let dayStyle = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).month(.abbreviated).day()
        if let lastSync {
            if calendar.isDate(lastSync, inSameDayAs: now) {
                parts.append("Synced \(lastSync.formatted(timeStyle))")
            } else {
                parts.append("Synced \(lastSync.formatted(dayStyle)), \(lastSync.formatted(timeStyle))")
            }
        }
        if let newest = newestImportedDate {
            let startOfToday = calendar.startOfDay(for: now)
            let day = calendar.startOfDay(for: newest)
            let label: String
            if day >= startOfToday {
                label = "today"
            } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday), day == yesterday {
                label = "yesterday"
            } else {
                label = newest.formatted(dayStyle)
            }
            parts.append("latest imported charge \(label)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Date of the newest imported transaction.
    static func newestImportedDate(_ transactions: [SpendTransaction]) -> Date? {
        transactions.filter { $0.entryMethod == .imported }.map(\.date).max()
    }
}
