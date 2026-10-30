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
        if let lastSync {
            if calendar.isDate(lastSync, inSameDayAs: now) {
                parts.append("Synced \(lastSync.formatted(date: .omitted, time: .shortened))")
            } else {
                parts.append("Synced \(lastSync.formatted(.dateTime.month(.abbreviated).day())), \(lastSync.formatted(date: .omitted, time: .shortened))")
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
                label = newest.formatted(.dateTime.month(.abbreviated).day())
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
