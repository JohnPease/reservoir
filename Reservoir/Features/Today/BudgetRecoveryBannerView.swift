import SwiftUI

/// Today's budget recovery banner (reservoir-nka.1): a card under the budget hero or tank with up
/// to two titled sections, the daily limit (how many no-spend days until it is full again) and the
/// month (one warning with a status chip), split by a divider so the two read as separate facts.
/// The point-of-no-return phrase and its chip use `ReservoirDeficit`; a tracking-over or
/// hard-to-recover section is in the lighter `ReservoirDropletDeficit`. Wording and composition come from
/// `BudgetRecoveryCalculator`.
struct BudgetRecoveryBannerView: View {
    let banner: BudgetRecoveryCalculator.Banner

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(banner.sections.enumerated()), id: \.offset) { index, section in
                if index > 0 { Divider() }
                sectionView(section)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .reservoirCardBackground()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(banner.accessibilityText)
        .accessibilityIdentifier("today.recoveryBanner")
    }

    private func sectionView(_ section: BudgetRecoveryCalculator.Section) -> some View {
        let isDeficit = section.sentence.deficitPhrase != nil
        let isHeadingOver = section.level == .trackingOver || section.level == .hardToRecover
        let tint = isDeficit ? "ReservoirDeficit" : (isHeadingOver ? "ReservoirDropletDeficit" : nil)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: section.kind == .dailyLimit ? "drop.fill" : "calendar")
                .font(.subheadline)
                .foregroundStyle(Color(tint ?? "ReservoirAccent"))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(section.title.uppercased())
                        .font(.caption.weight(.semibold))
                        .tracking(0.5)
                        .foregroundStyle(Color("ReservoirTextSecondary"))
                    if let status = section.status {
                        Text(status)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .foregroundStyle(Color(tint ?? "ReservoirTextPrimary"))
                            .background(
                                Color(tint == nil ? "ReservoirSurfaceAccent" : "ReservoirSurfaceDeficit"),
                                in: Capsule()
                            )
                    }
                }
                sentenceText(section.sentence)
                    .font(.subheadline)
                    .foregroundStyle(Color(isHeadingOver ? "ReservoirDropletDeficit" : "ReservoirTextPrimary"))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func sentenceText(_ line: BudgetSummaryCalculator.ProgressSentence) -> Text {
        guard let deficit = line.deficitPhrase else { return Text(line.text) }
        return Text(line.lead)
            + Text(deficit).bold().foregroundColor(Color("ReservoirDeficit"))
            + Text(line.tail)
    }
}
