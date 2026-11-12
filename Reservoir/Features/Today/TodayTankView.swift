import SwiftUI

/// Today's budget as a sliced droplet (reservoir-wrx): the whole drop is today's limit, the water
/// is what is left to spend, and above the water each purchase is a faint band at the height it
/// took. A dashed line marks the daily base, so what sits above it is carried-forward money. Used
/// where the screen is wide and short (landscape on either display). Figures come from
/// `DayStepsCalculator`; the hero and stat identifiers are the budget hero's, so the same tests
/// find both.
struct TodayTankView: View {
    let summary: TodayScreenCalculator.Summary
    let day: DayStepsCalculator.Day

    private static let dropSize = CGSize(width: 84, height: 116)

    private var isOver: Bool { day.remaining < 0 }
    private var waterColor: Color { Color(isOver ? "ReservoirDropletDeficit" : "ReservoirDropletHealthy") }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(BudgetHeroCardView.title)
                .font(.headline)
                .foregroundStyle(Color("ReservoirTextPrimary"))
            HStack(alignment: .center, spacing: 12) {
                slicedDrop
                VStack(alignment: .leading, spacing: 2) {
                    Text(isOver ? "Over today" : "Left to spend today")
                        .font(.caption)
                        .foregroundStyle(isOver ? Color("ReservoirDeficit") : Color("ReservoirTextSecondary"))
                    Text(abs(day.remaining), format: .currency(code: "USD"))
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(isOver ? Color("ReservoirDeficit") : Color("ReservoirTextPrimary"))
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                        .accessibilityIdentifier("today.tank.remaining")
                    Text("of \(CurrencyFormatting.usd(summary.limit))")
                        .font(.subheadline)
                        .foregroundStyle(Color("ReservoirTextSecondary"))
                }
            }
            Text("\(CurrencyFormatting.usd(summary.dailyBase)) base + \(CurrencyFormatting.usd(summary.carriedForward)) carried forward")
                .font(.subheadline)
                .foregroundStyle(Color("ReservoirTextSecondary"))
            steps
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .reservoirCardBackground()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today.tank")
    }

    /// The drop, its water and purchase bands, and the daily-base line. Decorative: the figures
    /// beside it say the same in text.
    private var slicedDrop: some View {
        let size = Self.dropSize
        let limit = day.limit
        let waterHeight = size.height * DayStepsCalculator.fill(level: day.remaining, limit: limit)
        let baseY = size.height * (1 - DayStepsCalculator.fill(level: summary.dailyBase, limit: limit))
        return ZStack(alignment: .topLeading) {
            DropletShape().fill(Color("ReservoirDropletTrack"))
                .frame(width: size.width, height: size.height)
            TiltingWater { water in
                ZStack(alignment: .topLeading) {
                    WaterSurfaceShape(level: size.height - waterHeight - 4, water: water, phaseOffset: 2.1)
                        .fill(waterColor.opacity(0.55))
                    WaterSurfaceShape(level: size.height - waterHeight, water: water)
                        .fill(waterColor)
                    SplashView(
                        water: water,
                        pivot: CGPoint(x: size.width / 2, y: size.height - waterHeight),
                        scale: size.width / 170,
                        color: waterColor
                    )
                    .frame(width: size.width, height: size.height)
                    // The purchase bands are oversized sideways and turn with the water about the
                    // middle of its line.
                    ZStack(alignment: .topLeading) {
                        ForEach(Array(DayStepsCalculator.slices(for: day).enumerated()), id: \.offset) { index, slice in
                            let top = size.height * (1 - DayStepsCalculator.fill(level: slice.upper, limit: limit))
                            let bottom = size.height * (1 - DayStepsCalculator.fill(level: slice.lower, limit: limit))
                            Rectangle().fill(waterColor.opacity(index.isMultiple(of: 2) ? 0.16 : 0.26))
                                .frame(width: size.width * 3, height: bottom - top)
                                .offset(x: -size.width, y: top)
                        }
                    }
                    .frame(width: size.width, height: size.height, alignment: .topLeading)
                    .rotationEffect(water.angle, anchor: UnitPoint(x: 0.5, y: 1 - waterHeight / size.height))
                }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .clipShape(DropletShape())
            }
            if limit > summary.dailyBase, summary.dailyBase > 0 {
                Rectangle()
                    .stroke(Color("ReservoirTextPrimary"), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .frame(width: size.width + 12, height: 1)
                    .offset(x: -6, y: baseY)
                Text("base")
                    .font(.caption2)
                    .foregroundStyle(Color("ReservoirTextSecondary"))
                    .offset(x: size.width + 8, y: baseY - 7)
            }
        }
        .frame(width: size.width, height: size.height)
        .padding(.trailing, 28)
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
