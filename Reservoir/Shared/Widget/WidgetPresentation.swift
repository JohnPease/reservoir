import Foundation

/// Opening the app from the widget. The only deep link: any tap lands on Today.
enum WidgetDeepLink {
    static let todayURL = URL(string: "reservoir://today")!

    static func isToday(_ url: URL) -> Bool {
        url.scheme == todayURL.scheme && url.host == todayURL.host
    }
}

/// What the widget draws for one entry, resolved from the snapshot, phase and caption
/// flag. Pure so the "which slot leads / which state wins" rules are unit-testable; the
/// SwiftUI views only map this to layout.
struct WidgetPresentation: Equatable {
    enum Kind: Equatable {
        case budget, savings

        var title: String {
            switch self {
            case .budget: return "Budget"
            case .savings: return "Savings limit"
            }
        }
    }

    /// A status that replaces a budget's figures.
    enum Message: Equatable {
        case syncing, chooseAccounts

        var title: String {
            switch self {
            case .syncing: return "Syncing account data\u{2026}"
            case .chooseAccounts: return "Choose accounts"
            }
        }

        var detail: String {
            switch self {
            case .syncing: return "Numbers appear when your banks finish loading."
            case .chooseAccounts: return "Pick which accounts count toward your budget."
            }
        }
    }

    struct Slot: Equatable {
        enum Content: Equatable {
            case amount(remaining: Decimal, limit: Decimal)
            case message(Message)
        }

        var kind: Kind
        var content: Content

        var isOver: Bool {
            if case .amount(let remaining, _) = content { return remaining < 0 }
            return false
        }

        var hasAmount: Bool {
            if case .amount = content { return true }
            return false
        }
    }

    enum Body: Equatable {
        /// No snapshot yet, or neither a budget nor a savings goal exists.
        case setUp
        /// Snapshot too old: `lastUpdated` is its `generatedAt`.
        case needsRefresh(lastUpdated: Date)
        case figures(budget: Slot?, savings: Slot?, month: WidgetSnapshot.MonthProgress?)
    }

    var body: Body
    /// Figures are tomorrow's projection rather than live numbers.
    var isEstimate: Bool
    /// Non-nil when small/medium should show "Updated <time>".
    var updatedAt: Date?

    /// The slot that leads small, rectangular and inline widgets: the budget, unless it
    /// is only a status message while a savings limit has real numbers.
    var primary: Slot? {
        guard case .figures(let budget, let savings, _) = body else { return nil }
        if let budget, let savings, !budget.hasAmount, savings.hasAmount { return savings }
        return budget ?? savings
    }

    /// The savings line under the small widget's big number: only when the budget leads
    /// with an amount and savings has one too.
    var smallSecondary: Slot? {
        guard case .figures(let budget, let savings, _) = body,
              let budget, budget.hasAmount, let savings, savings.hasAmount
        else { return nil }
        return savings
    }

    /// Over budget (or over the savings limit) on the leading slot.
    var isOver: Bool { primary?.isOver ?? false }

    static func make(snapshot: WidgetSnapshot?, phase: WidgetPhase, showsUpdatedCaption: Bool) -> WidgetPresentation {
        guard let snapshot else { return WidgetPresentation(body: .setUp, isEstimate: false, updatedAt: nil) }
        if phase == .needsRefresh {
            return WidgetPresentation(
                body: .needsRefresh(lastUpdated: snapshot.generatedAt), isEstimate: false, updatedAt: nil
            )
        }
        let isEstimate = phase == .estimate
        let figures = isEstimate ? snapshot.tomorrow : snapshot.today
        let budget = slot(.budget, figures.budget)
        let savings = slot(.savings, figures.savings)
        guard budget != nil || savings != nil else {
            return WidgetPresentation(body: .setUp, isEstimate: false, updatedAt: nil)
        }
        return WidgetPresentation(
            body: .figures(budget: budget, savings: savings, month: figures.month),
            isEstimate: isEstimate,
            updatedAt: showsUpdatedCaption && !isEstimate ? snapshot.generatedAt : nil
        )
    }

    private static func slot(_ kind: Kind, _ section: WidgetSnapshot.Section) -> Slot? {
        switch section.state {
        case .notSet:
            return nil
        case .syncing:
            return Slot(kind: kind, content: .message(.syncing))
        case .chooseAccounts:
            return Slot(kind: kind, content: .message(.chooseAccounts))
        case .active:
            guard let remaining = section.remaining, let limit = section.limit else { return nil }
            return Slot(kind: kind, content: .amount(remaining: remaining, limit: limit))
        }
    }

    /// "Last updated 2 days ago" for the needs-refresh state.
    static func lastUpdatedText(_ lastUpdated: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Last updated " + formatter.localizedString(for: lastUpdated, relativeTo: now)
    }
}

// MARK: - Lock screen (accessory) text

/// Copy for the single-color lock screen families. Over budget cannot use red there, so it
/// is a minus sign plus the words "over today".
extension WidgetPresentation {
    struct RectangularText: Equatable {
        var header: String
        var headline: String
        var detail: String?
    }

    var inlineText: String {
        switch body {
        case .setUp: return "Open Reservoir to set up"
        case .needsRefresh: return "Open Reservoir to refresh"
        case .figures:
            guard let primary else { return "Open Reservoir to set up" }
            switch primary.content {
            case .message(let message):
                return message.title
            case .amount(let remaining, _):
                let amount = CurrencyFormatting.usdWithTypographicMinus(remaining)
                if remaining < 0 { return isEstimate ? "\(amount) over today est." : "\(amount) over today" }
                return isEstimate ? "Left today \(amount) est." : "Left today \(amount)"
            }
        }
    }

    var rectangularText: RectangularText {
        switch body {
        case .setUp:
            return RectangularText(header: "Reservoir", headline: "Open Reservoir to set up", detail: nil)
        case .needsRefresh:
            return RectangularText(header: "Reservoir", headline: "Open Reservoir to refresh", detail: nil)
        case .figures:
            guard let primary else {
                return RectangularText(header: "Reservoir", headline: "Open Reservoir to set up", detail: nil)
            }
            switch primary.content {
            case .message(let message):
                return RectangularText(header: primary.kind.title, headline: message.title, detail: nil)
            case .amount(let remaining, let limit):
                let amount = CurrencyFormatting.usdWithTypographicMinus(remaining)
                let detail: String
                if remaining < 0 {
                    detail = isEstimate ? "over today \u{00B7} estimate" : "over today"
                } else {
                    detail = (isEstimate ? "left today \u{00B7} estimate" : "left today")
                        + " \u{00B7} of " + CurrencyFormatting.usd(limit)
                }
                return RectangularText(header: primary.kind.title, headline: amount, detail: detail)
            }
        }
    }
}
