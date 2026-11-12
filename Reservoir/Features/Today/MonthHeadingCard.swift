import SwiftUI

/// "Where the month is heading" (reservoir-wrx), the lower half of Today when the screen is held
/// like a laptop: categories already above their usual and categories on pace to finish high.
/// Hidden when neither applies. Tapping opens the full breakdown.
struct MonthHeadingCard: View {
    let transactions: [SpendTransaction]
    let referenceDate: Date

    var body: some View {
        let entries = transactions.map(CategorySpendCalculator.Entry.init)
        let callouts = CategorySpendCalculator.callouts(month: referenceDate, entries: entries, now: referenceDate)
        let projections = CategorySpendCalculator.projections(month: referenceDate, entries: entries, now: referenceDate)
        if !callouts.isEmpty || !projections.isEmpty {
            NavigationLink {
                CategoryBreakdownView()
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Where the month is heading")
                            .font(.caption)
                            .foregroundStyle(Color("ReservoirTextSecondary"))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color("ReservoirTextMuted"))
                    }
                    ForEach(callouts.prefix(2), id: \.category) { callout in
                        line(callout.text, detail: callout.detailText, isWarning: true)
                    }
                    ForEach(projections.prefix(2), id: \.category) { projection in
                        line(projection.text, detail: projection.detailText, isWarning: false)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .reservoirCardBackground(Color("ReservoirSurface"))
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("today.monthHeading")
        }
    }

    private func line(_ text: String, detail: String, isWarning: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isWarning ? Color("ReservoirDeficit") : Color("ReservoirTextPrimary"))
            Text(detail)
                .font(.caption)
                .foregroundStyle(Color("ReservoirTextSecondary"))
        }
    }
}

/// The small caps label that names a half of the Now / Next layout.
struct ZoneLabel: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(1.2)
            .foregroundStyle(Color("ReservoirTextSecondary"))
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("today.zone.\(title.lowercased())")
    }
}

/// The dashed line that stands for the fold between Now and Next.
struct FoldDivider: View {
    var body: some View {
        Rectangle()
            .stroke(Color("ReservoirTextMuted"), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}
