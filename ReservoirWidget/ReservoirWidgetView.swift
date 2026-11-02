import SwiftUI
import WidgetKit

/// Maps a `WidgetPresentation` to layout for each supported family. All decisions about
/// what to show live in `WidgetPresentation`; colors are Asset Catalog tokens only.
struct ReservoirWidgetView: View {
    let entry: ReservoirEntry
    @Environment(\.widgetFamily) private var family

    private var presentation: WidgetPresentation { entry.presentation }

    var body: some View {
        content
            .containerBackground(for: .widget) {
                Color(presentation.isOver ? "ReservoirSurfaceDeficit" : "ReservoirSurface")
            }
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .systemMedium: MediumWidgetView(presentation: presentation, now: entry.date)
        case .accessoryRectangular: RectangularWidgetView(presentation: presentation)
        case .accessoryInline: InlineWidgetView(presentation: presentation)
        default: SmallWidgetView(presentation: presentation, now: entry.date)
        }
    }
}

// MARK: - Home screen

private struct SmallWidgetView: View {
    let presentation: WidgetPresentation
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch presentation.body {
            case .setUp:
                StatusMessage(header: "Reservoir", title: "Open Reservoir to set up", detail: "Add a budget or savings goal.")
            case .needsRefresh(let lastUpdated):
                StatusMessage(
                    header: "Reservoir",
                    title: "Open Reservoir to refresh",
                    detail: WidgetPresentation.lastUpdatedText(lastUpdated, now: now)
                )
            case .figures:
                if let primary = presentation.primary {
                    SlotView(
                        slot: primary,
                        isEstimate: presentation.isEstimate,
                        amountSize: presentation.smallSecondary == nil ? 36 : 32,
                        showsLimit: presentation.smallSecondary == nil
                    )
                    if let secondary = presentation.smallSecondary {
                        SavingsLine(slot: secondary)
                    }
                    UpdatedCaption(date: presentation.updatedAt)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct MediumWidgetView: View {
    let presentation: WidgetPresentation
    let now: Date

    var body: some View {
        switch presentation.body {
        case .setUp:
            StatusMessage(header: "Reservoir", title: "Open Reservoir to set up", detail: "Add a budget or savings goal.")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .needsRefresh(let lastUpdated):
            StatusMessage(
                header: "Reservoir",
                title: "Open Reservoir to refresh",
                detail: WidgetPresentation.lastUpdatedText(lastUpdated, now: now)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .figures(let budget, let savings, let month):
            HStack(spacing: 0) {
                half {
                    if let left = budget ?? savings {
                        SlotView(slot: left, isEstimate: presentation.isEstimate, amountSize: 40, showsLimit: true)
                    }
                }
                if hasRightHalf(budget: budget, savings: savings, month: month) {
                    Rectangle()
                        .fill(Color("ReservoirTextSecondary").opacity(0.22))
                        .frame(width: 1)
                        .padding(.vertical, 2)
                    half { rightHalf(budget: budget, savings: savings, month: month).padding(.leading, 14) }
                }
            }
            .overlay(alignment: .bottomLeading) {
                UpdatedCaption(date: presentation.updatedAt)
            }
        }
    }

    private func half<Inner: View>(@ViewBuilder _ inner: () -> Inner) -> some View {
        VStack(alignment: .leading, spacing: 0) { inner() }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func rightHalf(
        budget: WidgetPresentation.Slot?,
        savings: WidgetPresentation.Slot?,
        month: WidgetSnapshot.MonthProgress?
    ) -> some View {
        if budget != nil, let savings {
            SlotView(slot: savings, isEstimate: presentation.isEstimate, amountSize: 40, showsLimit: true)
        } else if let month, budget?.hasAmount == true {
            MonthProgressView(month: month)
        }
    }

    private func hasRightHalf(budget: WidgetPresentation.Slot?, savings: WidgetPresentation.Slot?, month: WidgetSnapshot.MonthProgress?) -> Bool {
        (budget != nil && savings != nil) || (month != nil && budget?.hasAmount == true)
    }
}

// MARK: - Building blocks

private struct WidgetHeader: View {
    let title: String
    var isOver = false

    var body: some View {
        HStack(spacing: 6) {
            DropletShape()
                .fill(Color(isOver ? "ReservoirDropletDeficit" : "ReservoirDropletHealthy"))
                .frame(width: 11, height: 13)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color("ReservoirTextSecondary"))
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A budget or savings figure (or its status message) with header, big number and
/// sub-line.
private struct SlotView: View {
    let slot: WidgetPresentation.Slot
    let isEstimate: Bool
    let amountSize: CGFloat
    let showsLimit: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
    }

    @ViewBuilder
    private var content: some View {
        switch slot.content {
        case .amount(let remaining, let limit):
            let isOver = remaining < 0
            WidgetHeader(title: slot.kind.title, isOver: isOver)
            Spacer(minLength: 4)
            Text(CurrencyFormatting.usdWithTypographicMinus(remaining))
                .font(.system(size: amountSize, weight: .bold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .foregroundStyle(Color(isOver ? "ReservoirDeficit" : "ReservoirTextPrimary"))
                .privacySensitive()
            HStack(spacing: 6) {
                if isOver {
                    Text("over today")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color("ReservoirDeficit"))
                } else {
                    Text(showsLimit ? "left today \u{00B7} of \(CurrencyFormatting.usd(limit))" : "left today")
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(Color("ReservoirTextSecondary"))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .privacySensitive(showsLimit)
                }
                if isEstimate { EstimateTag() }
            }
            .padding(.top, 3)
        case .message(let message):
            WidgetHeader(title: slot.kind.title)
            Spacer(minLength: 4)
            Text(message.title)
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(Color(message == .chooseAccounts ? "ReservoirAccent" : "ReservoirTextPrimary"))
                .minimumScaleFactor(0.8)
            Text(message.detail)
                .font(.system(size: 12))
                .foregroundStyle(Color("ReservoirTextSecondary"))
                .lineLimit(3)
                .padding(.top, 4)
        }
    }
}

private struct StatusMessage: View {
    let header: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetHeader(title: header)
            Spacer(minLength: 4)
            Text(title)
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(Color("ReservoirTextPrimary"))
                .minimumScaleFactor(0.8)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(Color("ReservoirTextSecondary"))
                .lineLimit(3)
                .padding(.top, 4)
        }
    }
}

private struct EstimateTag: View {
    var body: some View {
        Text("estimate")
            .textCase(.uppercase)
            .font(.system(size: 10, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(Color("ReservoirAccent"))
            .padding(.horizontal, 4)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color("ReservoirAccent"), lineWidth: 1))
    }
}

/// The savings figure under the small widget's budget number.
private struct SavingsLine: View {
    let slot: WidgetPresentation.Slot

    var body: some View {
        if case .amount(let remaining, _) = slot.content {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(Color("ReservoirTextSecondary").opacity(0.22))
                    .frame(height: 1)
                    .padding(.top, 9)
                HStack(alignment: .firstTextBaseline) {
                    Text("Savings")
                        .font(.system(size: 12))
                        .foregroundStyle(Color("ReservoirTextSecondary"))
                    Spacer(minLength: 8)
                    Text(CurrencyFormatting.usdWithTypographicMinus(remaining))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                        .foregroundStyle(Color(remaining < 0 ? "ReservoirDeficit" : "ReservoirTextPrimary"))
                        .privacySensitive()
                }
                .padding(.top, 7)
            }
        }
    }
}

private struct UpdatedCaption: View {
    let date: Date?

    var body: some View {
        if let date {
            Text("Updated \(date.formatted(date: .omitted, time: .shortened))")
                .font(.system(size: 10.5))
                .foregroundStyle(Color("ReservoirTextMuted"))
                .padding(.top, 6)
        }
    }
}

private struct MonthProgressView: View {
    let month: WidgetSnapshot.MonthProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetHeader(title: month.monthName)
            Spacer(minLength: 4)
            Text(month.sentence)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color("ReservoirTextPrimary"))
                .lineLimit(5)
                .minimumScaleFactor(0.8)
                .privacySensitive()
            Text("\(CurrencyFormatting.usd(month.spent)) of \(CurrencyFormatting.usd(month.monthlyAmount)) spent")
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(Color("ReservoirTextSecondary"))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.top, 4)
                .privacySensitive()
            if let top = month.topCategory {
                Text("Top: \(top.name) \(CurrencyFormatting.usd(top.amount))")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(Color("ReservoirTextSecondary"))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.top, 2)
                    .privacySensitive()
            }
        }
    }
}

// MARK: - Lock screen

private struct RectangularWidgetView: View {
    let presentation: WidgetPresentation

    var body: some View {
        let text = presentation.rectangularText
        VStack(alignment: .leading, spacing: 1) {
            Label(text.header, systemImage: "drop.fill")
                .font(.system(size: 12, weight: .semibold))
                .widgetAccentable()
            Text(text.headline)
                .font(.system(size: presentation.primary?.hasAmount == true ? 24 : 14, weight: .bold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(2)
                .privacySensitive(presentation.primary?.hasAmount == true)
            if let detail = text.detail {
                Text(detail)
                    .font(.system(size: 11.5))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .privacySensitive()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct InlineWidgetView: View {
    let presentation: WidgetPresentation

    var body: some View {
        Label(presentation.inlineText, systemImage: "drop.fill")
            .privacySensitive(presentation.primary?.hasAmount == true)
    }
}
