import Foundation

/// Turns `BudgetRecoveryCalculator`'s structured result into the widget's one short line
/// (reservoir-nka.2). Copy is built from the structured outcome, never trimmed from the Today
/// banner's sentences, but every dollar figure goes through the banner's own rounding helpers so
/// the widget and Today can't disagree. Pure: no SwiftData, no SwiftUI.
///
/// Precedence (one line only): over budget, hard to recover, daily-limit recovery, tracking over.
enum WidgetRecoveryLineFormatter {

    static func line(for result: BudgetRecoveryCalculator.Result?, calendar: Calendar) -> WidgetSnapshot.RecoveryLine? {
        guard let result else { return nil }
        let warning = result.warning
        switch warning.level {
        case .pointOfNoReturn:
            let text = "Over budget by \(BudgetSummaryCalculator.whole(warning.overBy ?? 0))"
            return make(text, tone: .overBudget, kind: .month, result: result)
        case .hardToRecover:
            return make(needText("Hard to recover", warning.neededDaily), tone: .warning, kind: .month, result: result)
        case .trackingOver, .none:
            if let recovery = result.recovery {
                return make(recoveryText(recovery.outcome, calendar: calendar), tone: .neutral, kind: .dailyLimit, result: result)
            }
            guard warning.level == .trackingOver else { return nil }
            return make(needText("Tracking over", warning.neededDaily), tone: .warning, kind: .month, result: result)
        }
    }

    static func recoveryText(_ outcome: BudgetRecoveryCalculator.Outcome, calendar: Calendar) -> String {
        switch outcome {
        case .noSpend(let days, _):
            return days == 1 ? "1 no-spend day to full" : "\(days) no-spend days to full"
        case .resetClears(_, let resetsOn):
            return "Resets to full \(BudgetSummaryCalculator.monthDay(resetsOn, calendar: calendar))"
        }
    }

    /// "<label>: $X/day" with the need rounded down; "<$1/day" under a dollar; "No room left this
    /// month" when nothing is left to spend or it's the last day (nil need).
    static func needText(_ label: String, _ needed: Decimal?) -> String {
        guard let needed, needed > 0 else { return "No room left this month" }
        let amount = needed >= 1 ? BudgetRecoveryCalculator.neededText(needed) : "<$1"
        return "\(label): \(amount)/day"
    }

    private static func make(
        _ text: String,
        tone: WidgetSnapshot.RecoveryLine.Tone,
        kind: BudgetRecoveryCalculator.Section.Kind,
        result: BudgetRecoveryCalculator.Result
    ) -> WidgetSnapshot.RecoveryLine {
        let section = result.banner?.sections.first { $0.kind == kind }
        return WidgetSnapshot.RecoveryLine(
            text: text, accessibilityText: section?.accessibilityText ?? text, tone: tone
        )
    }
}
