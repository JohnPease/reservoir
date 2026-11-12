import SwiftUI

/// The budget hero (reservoir-wrx): the amount left to spend today printed inside a large
/// droplet, with the water rising behind it. Replaces the small gauge beside the number for the
/// budget; the identifiers are the budget hero's, so the same tests find it. The number is the
/// remaining amount, which the savings hero does not show, so the stat row below it still carries
/// "Spent today" and "Remaining".
struct DropletHeroView: View {
    let summary: TodayScreenCalculator.Summary
    var title: String?
    var identifiers: HeroIdentifiers = .budget

    @Environment(\.colorScheme) private var colorScheme

    private static let dropSize = CGSize(width: 170, height: 220)

    private var isOver: Bool { summary.remaining < 0 }
    private var fill: Double { DayStepsCalculator.fill(level: summary.remaining, limit: summary.limit) }

    /// Over the limit nothing is left, so a sliver of deficit-colored water keeps the drop from
    /// reading as simply empty.
    private var displayFill: Double { isOver ? FillGaugeCalculator.deficitDisplayFloor : fill }
    private var waterColor: Color { Color(isOver ? "ReservoirDropletDeficit" : "ReservoirDropletHealthy") }

    /// The number sits on the water once it is more than a third full; otherwise it sits on the
    /// empty track. Light mode water is dark teal and dark mode water is light, so the text flips.
    private var numberColor: Color {
        if isOver { return Color("ReservoirDeficit") }
        guard fill > 0.4 else { return Color("ReservoirTextPrimary") }
        return colorScheme == .dark ? Color("ReservoirBackground") : .white
    }

    var body: some View {
        VStack(spacing: 8) {
            if let title {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Color("ReservoirTextPrimary"))
            }
            ZStack {
                DropletShape().fill(Color("ReservoirDropletTrack"))
                TiltingWater { water in
                    let lineY = Self.dropSize.height * (1 - CGFloat(displayFill))
                    ZStack {
                        // A paler wave behind the main one gives the surface some depth.
                        DropletShape().fill(waterColor.opacity(0.4))
                            .mask { WaterSurfaceShape(level: lineY - 5, water: water, phaseOffset: 2.1) }
                        DropletShape().fill(waterColor)
                            .mask { WaterSurfaceShape(level: lineY, water: water) }
                    }
                }
                // A soft highlight on the glass, upper left of the bulb.
                Capsule()
                    .fill(.white.opacity(0.28))
                    .frame(width: 9, height: 38)
                    .rotationEffect(.degrees(24))
                    .offset(x: -50, y: 22)
                    .accessibilityHidden(true)
                VStack(spacing: 0) {
                    Text(abs(summary.remaining), format: .currency(code: "USD"))
                        .font(.system(size: 34, weight: .bold))
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                        .accessibilityIdentifier(identifiers.amount)
                    Text(isOver ? "over today" : "left to spend")
                        .font(.caption)
                }
                .foregroundStyle(numberColor)
                .padding(.horizontal, 28)
                .offset(y: 38)
            }
            .frame(width: Self.dropSize.width, height: Self.dropSize.height)

            Text("of \(CurrencyFormatting.usd(summary.limit)) · \(CurrencyFormatting.usd(summary.dailyBase)) base + \(CurrencyFormatting.usd(summary.carriedForward)) carried")
                .font(.subheadline)
                .foregroundStyle(Color("ReservoirTextSecondary"))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        // .contain so the container stays queryable as its own element, as HeroSection does.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifiers.container)
    }
}
