import SwiftUI

/// Today's budget recovery banner (reservoir-nka.1): up to two quiet lines under the budget hero
/// or tank — when the full daily limit is back at the usual pace (or a "keep to" target) and one
/// month warning. Text is `ReservoirTextSecondary`; only the point-of-no-return phrase uses
/// `ReservoirDeficit`. Wording and composition come from `BudgetRecoveryCalculator`.
struct BudgetRecoveryBannerView: View {
    let banner: BudgetRecoveryCalculator.Banner

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(banner.lines.enumerated()), id: \.offset) { _, line in
                lineText(line)
            }
        }
        .font(.subheadline)
        .foregroundStyle(Color("ReservoirTextSecondary"))
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(banner.text)
        .accessibilityIdentifier("today.recoveryBanner")
    }

    private func lineText(_ line: BudgetSummaryCalculator.ProgressSentence) -> Text {
        guard let deficit = line.deficitPhrase else { return Text(line.text) }
        return Text(line.lead)
            + Text(deficit).bold().foregroundColor(Color("ReservoirDeficit"))
            + Text(line.tail)
    }
}
