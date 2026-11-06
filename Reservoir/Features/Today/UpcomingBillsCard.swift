import SwiftUI

/// Today's "Coming up" card (reservoir-nm8): recurring charges expected in the next week, from
/// `RecurringChargeCalculator`. Hidden when none are due. Informational; it does not change the
/// daily limit. Tapping opens the full recurring list.
struct UpcomingBillsCard: View {
    let transactions: [SpendTransaction]
    let referenceDate: Date

    var body: some View {
        let entries = transactions.map(CategorySpendCalculator.Entry.init)
        let recurring = RecurringChargeCalculator.detect(entries: entries, now: referenceDate)
        let upcoming = RecurringChargeCalculator.upcoming(recurring, now: referenceDate)
        if !upcoming.isEmpty {
            let total = upcoming.reduce(Decimal(0)) { $0 + $1.amount }
            NavigationLink {
                RecurringChargesView()
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Coming up")
                            .font(.caption)
                            .foregroundStyle(Color("ReservoirTextSecondary"))
                        Spacer()
                        Text("About \(total.formatted(.currency(code: "USD").precision(.fractionLength(0)))) in the next week")
                            .font(.caption)
                            .foregroundStyle(Color("ReservoirTextSecondary"))
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color("ReservoirTextMuted"))
                    }
                    ForEach(upcoming.prefix(3), id: \.merchant) { item in
                        HStack {
                            Text(item.merchant)
                                .foregroundStyle(Color("ReservoirTextPrimary"))
                            Text(Self.dayText(item.expectedDate, now: referenceDate))
                                .font(.caption)
                                .foregroundStyle(Color("ReservoirTextSecondary"))
                            Spacer()
                            Text(item.amount.formatted(.currency(code: "USD")))
                                .monospacedDigit()
                                .foregroundStyle(Color("ReservoirTextPrimary"))
                        }
                    }
                    if upcoming.count > 3 {
                        Text("and \(upcoming.count - 3) more")
                            .font(.caption)
                            .foregroundStyle(Color("ReservoirTextSecondary"))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .reservoirCardBackground(Color("ReservoirSurface"))
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("today.upcomingBills")
        }
    }

    /// "today", "tomorrow", or the weekday.
    private static func dayText(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "today" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "tomorrow"
        }
        return date.formatted(.dateTime.weekday(.wide))
    }
}
