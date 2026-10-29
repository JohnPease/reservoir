import SwiftUI

/// Accessibility identifiers for one `HeroSection`/`TwoStatRow` pair, so the savings hero
/// and the budget hero can share one implementation while keeping their own XCUITest
/// namespaces. `.savings` holds the original Today identifiers unchanged.
struct HeroIdentifiers {
    let container: String
    let amount: String
    let stats: String

    static let savings = HeroIdentifiers(container: "today.hero", amount: "today.heroAmount", stats: "today.stats")
    static let budget = HeroIdentifiers(
        container: "today.budgetHero",
        amount: "today.budgetHero.amount",
        stats: "today.budgetHero.stats"
    )
}

/// The Today hero number + "$base + $carried forward" subtext, extracted from
/// `TodayView` (reservoir-j8t) so the monthly-budget card reuses it (STANDARDS.md §3).
/// `title` is shown above the number only when more than one hero is on screen.
struct HeroSection: View {
    let summary: TodayScreenCalculator.Summary
    var title: String?
    var identifiers: HeroIdentifiers = .savings

    /// The fill-gauge and the hero number's own color switch both key off
    /// `summary.limit` (today's daily limit — base + carry-forward), not
    /// `summary.remaining`. Per §3.1, the gauge exists to "visually tie the hero number
    /// to the reservoir/tank metaphor" — it's the hero number's own tank, not a
    /// separate reading of the still-remaining balance (which the "Remaining" stat
    /// card already covers on its own terms, §3.3). `summary.dailyBase` is the "full
    /// tank" reference rate §4's formula scales to a week.
    private var gaugeResult: FillGaugeCalculator.Result {
        FillGaugeCalculator.result(currentBalance: summary.limit, baseDailyAmount: summary.dailyBase)
    }

    private var heroColor: Color {
        summary.limit >= 0 ? Color("ReservoirTextPrimary") : Color("ReservoirDeficit")
    }

    var body: some View {
        VStack(spacing: 4) {
            if let title {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Color("ReservoirTextPrimary"))
            }

            HStack(spacing: 8) {
                FillGaugeView(result: gaugeResult)

                // 44px per PROJECT_SPEC's "UX design — Today screen" — a manual/code-review
                // check (STANDARDS.md §5), not something asserted in XCUITest.
                Text(summary.limit, format: .currency(code: "USD"))
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(heroColor)
                    .accessibilityIdentifier(identifiers.amount)
            }

            Text("\(currency(summary.dailyBase)) base + \(currency(summary.carriedForward)) carried forward")
                .font(.subheadline)
                .foregroundStyle(Color("ReservoirTextSecondary"))
        }
        .frame(maxWidth: .infinity)
        // .contain, not the default .automatic, so this stays queryable as its own
        // "Other" element in XCUITest instead of being auto-flattened into a StaticText
        // that swallows the identifier.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifiers.container)
    }

    private func currency(_ amount: Decimal) -> String {
        CurrencyFormatting.usd(amount)
    }
}

/// Spent today / remaining.
struct TwoStatRow: View {
    let summary: TodayScreenCalculator.Summary
    var identifier: String = HeroIdentifiers.savings.stats

    var body: some View {
        HStack(spacing: 16) {
            StatCard(title: "Spent today", amount: summary.spentToday, isOverLimit: false)
            StatCard(title: "Remaining", amount: summary.remaining, isOverLimit: summary.remaining < 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

struct StatCard: View {
    let title: String
    let amount: Decimal
    let isOverLimit: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                // §3.3: deficit state reuses ReservoirDeficit for the label too — no
                // separate dimmed asset; the caption's smaller size/weight already
                // reads as "dimmed" relative to the value line below it.
                .foregroundStyle(isOverLimit ? Color("ReservoirDeficit") : Color("ReservoirTextSecondary"))
            Text(amount, format: .currency(code: "USD"))
                .font(.title3.weight(.semibold))
                .foregroundStyle(isOverLimit ? Color("ReservoirDeficit") : Color("ReservoirTextPrimary"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .reservoirCardBackground(isOverLimit ? Color("ReservoirSurfaceDeficit") : Color("ReservoirSurface"))
    }
}
