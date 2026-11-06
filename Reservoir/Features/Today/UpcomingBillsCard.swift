import SwiftUI

/// Today's "Coming up" card (reservoir-nm8): recurring charges expected in the next week, from
/// `RecurringChargeCalculator`. Hidden when none are due. Informational; it does not change the
/// daily limit. Tapping opens the full recurring list.
struct UpcomingBillsCard: View {
    /// Detected once per render by the caller, which also needs it for the unusual-charge flags.
    let recurring: [RecurringChargeCalculator.Recurring]
    let referenceDate: Date
    var calendar: Calendar = .current

    var body: some View {
        let upcoming = RecurringChargeCalculator.upcoming(recurring, now: referenceDate, calendar: calendar)
        if !upcoming.isEmpty {
            let total = RecurringChargeCalculator.total(of: upcoming)
            NavigationLink {
                RecurringChargesView()
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Coming up")
                            .font(.caption)
                            .foregroundStyle(Color("ReservoirTextSecondary"))
                        Spacer()
                        Text("About \(total.wholeDollarText) in the next week")
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
                            Text(dayText(item.expectedDate))
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

    /// "today", "tomorrow", the weekday, or "was due [weekday]" for a charge a day or two late.
    private func dayText(_ date: Date) -> String {
        if calendar.isDate(date, inSameDayAs: referenceDate) { return "today" }
        if date < calendar.startOfDay(for: referenceDate) { return "was due \(date.formatted(.dateTime.weekday(.wide)))" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: referenceDate), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "tomorrow"
        }
        return date.formatted(.dateTime.weekday(.wide))
    }
}
