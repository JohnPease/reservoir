import SwiftUI

/// Today's budget hero drawn as a tank (reservoir-wrx): the water is what is left to spend, and
/// each purchase is a step down its side. Used where the screen is wide and short (landscape on
/// either display), where a tall tank with the day written beside it uses the space better than
/// a number. Figures come from `DayStepsCalculator`; the hero and stat identifiers are the
/// budget hero's, so the same tests find both.
struct TodayTankView: View {
    let summary: TodayScreenCalculator.Summary
    let day: DayStepsCalculator.Day

    private var isOver: Bool { day.remaining < 0 }
    private var waterColor: Color { Color(isOver ? "ReservoirDropletDeficit" : "ReservoirDropletHealthy") }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(BudgetHeroCardView.title)
                .font(.headline)
                .foregroundStyle(Color("ReservoirTextPrimary"))
            HStack(alignment: .top, spacing: 20) {
                tank
                    .frame(width: 72, height: 220)
                VStack(alignment: .leading, spacing: 4) {
                    Text(isOver ? "Over today" : "Left to spend today")
                        .font(.caption)
                        .foregroundStyle(isOver ? Color("ReservoirDeficit") : Color("ReservoirTextSecondary"))
                    Text(abs(day.remaining), format: .currency(code: "USD"))
                        .font(.system(size: 38, weight: .bold))
                        .foregroundStyle(isOver ? Color("ReservoirDeficit") : Color("ReservoirTextPrimary"))
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                        .accessibilityIdentifier("today.tank.remaining")
                    Text("of \(CurrencyFormatting.usd(summary.limit)) · \(CurrencyFormatting.usd(summary.dailyBase)) base + \(CurrencyFormatting.usd(summary.carriedForward)) carried")
                        .font(.subheadline)
                        .foregroundStyle(Color("ReservoirTextSecondary"))
                    steps
                        .padding(.top, 12)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .reservoirCardBackground()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today.tank")
    }

    /// The vessel, the water at `remaining`, and a tick where each purchase left the level.
    private var tank: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            let fill = DayStepsCalculator.fill(level: day.remaining, limit: day.limit)
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 14).fill(Color("ReservoirDropletTrack"))
                RoundedRectangle(cornerRadius: 14).fill(waterColor)
                    .frame(height: max(height * fill, fill > 0 ? 8 : 0))
                ForEach(Array(day.steps.enumerated()), id: \.offset) { _, step in
                    let level = DayStepsCalculator.fill(level: step.levelAfter, limit: day.limit)
                    Rectangle()
                        .fill(Color("ReservoirBackground").opacity(0.7))
                        .frame(height: 1)
                        .offset(y: -height * level)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color("ReservoirTextMuted"), lineWidth: 1.5))
        }
        .accessibilityHidden(true)
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 6) {
            stepRow("Start of day", detail: CurrencyFormatting.usd(day.limit), muted: true)
            ForEach(Array(day.steps.enumerated()), id: \.offset) { _, step in
                stepRow(step.merchant, detail: "\(CurrencyFormatting.usdWithTypographicMinus(-step.amount)) → \(CurrencyFormatting.usd(step.levelAfter))")
            }
            if day.steps.isEmpty {
                Text("Nothing spent yet today.")
                    .font(.subheadline)
                    .foregroundStyle(Color("ReservoirTextSecondary"))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today.tank.steps")
    }

    private func stepRow(_ title: String, detail: String, muted: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .foregroundStyle(Color(muted ? "ReservoirTextSecondary" : "ReservoirTextPrimary"))
            Text(detail)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(Color("ReservoirTextSecondary"))
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
