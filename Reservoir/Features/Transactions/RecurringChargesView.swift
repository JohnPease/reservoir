import SwiftData
import SwiftUI

/// Charges that repeat about monthly (reservoir-o0a), found by `RecurringChargeCalculator`.
/// Read-only; a best guess from the stored history, so the footer says so.
struct RecurringChargesView: View {
    @Query private var transactions: [SpendTransaction]
    @Environment(TodayClock.self) private var todayClock

    var body: some View {
        let recurring = RecurringChargeCalculator.detect(
            entries: transactions.map(CategorySpendCalculator.Entry.init), now: todayClock.referenceDate
        )
        List {
            if recurring.isEmpty {
                Text("No recurring charges found yet").foregroundStyle(.secondary)
            } else {
                Section {
                    ForEach(recurring, id: \.merchant) { item in
                        RecurringRowView(item: item)
                    }
                } header: {
                    Text(Self.headerText(for: recurring))
                } footer: {
                    Text("Merchants that charged about the same amount in at least three separate months and charged again within the last 45 days. A best guess.")
                }
            }
        }
        .navigationTitle("Recurring charges")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("categories.recurring")
    }
}

extension RecurringChargesView {
    /// "About $212 a month, $2,544 a year", plus the net price rise when any price changed.
    static func headerText(for recurring: [RecurringChargeCalculator.Recurring]) -> String {
        let money = { (value: Decimal) in value.formatted(.currency(code: "USD").precision(.fractionLength(0))) }
        var text = "About \(money(RecurringChargeCalculator.monthlyTotal(recurring))) a month, \(money(RecurringChargeCalculator.yearlyTotal(recurring))) a year"
        let change = RecurringChargeCalculator.monthlyPriceChange(recurring)
        if change != 0 {
            text += " · prices \(change > 0 ? "up" : "down") \(money(abs(change))) a month"
        }
        return text
    }
}

private struct RecurringRowView: View {
    let item: RecurringChargeCalculator.Recurring

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(item.merchant)
                if item.isNew {
                    Text("New")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color("ReservoirSurfaceAccent")))
                        .foregroundStyle(Color("ReservoirAccent"))
                }
                Spacer()
                Text(item.typicalAmount.formatted(.currency(code: "USD")))
                    .monospacedDigit()
            }
            HStack {
                Text(item.category.map { CategorySpendCalculator.displayName(for: $0) } ?? CategorySpendCalculator.uncategorizedName)
                Text("· last \(item.lastDate.formatted(.dateTime.month(.abbreviated).day()))")
                Spacer()
                if let previous = item.previousAmount {
                    Label("was \(previous.formatted(.currency(code: "USD")))", systemImage: item.lastAmount > previous ? "arrow.up" : "arrow.down")
                        .foregroundStyle(item.lastAmount > previous ? Color("ReservoirDeficit") : Color("ReservoirTextSecondary"))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
