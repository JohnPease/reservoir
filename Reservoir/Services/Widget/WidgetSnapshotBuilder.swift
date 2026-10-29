import Foundation
import SwiftData

/// Builds the `WidgetSnapshot` the home screen widget renders, by calling the same
/// calculators the Today screen uses (`BudgetCalculator.cardModel`,
/// `TodayScreenCalculator.summary`, `BudgetSummaryCalculator.insights`) once for "now" and
/// once for the start of the next day. No new math lives here: this only maps their
/// results into the widget's plain value type. Imports SwiftData for the model types only
/// (STANDARDS.md §4's `*Calculator` exception); never SwiftUI.
enum WidgetSnapshotBuilder {

    static func make(
        goals: [SavingsGoal],
        budget: Budget?,
        transactions: [SpendTransaction],
        isAccountBackfillComplete: Bool,
        now: Date,
        calendar: Calendar = .current,
        accountStore: LinkedAccountStoring = LinkedAccountStore(),
        itemStore: LinkedItemStoring = LinkedItemStore()
    ) -> WidgetSnapshot {
        let tomorrowStart = BudgetCalculator.nextDayStart(after: calendar.startOfDay(for: now), calendar: calendar)
        func figures(at referenceDate: Date) -> WidgetSnapshot.Figures {
            self.figures(
                goals: goals,
                budget: budget,
                transactions: transactions,
                isAccountBackfillComplete: isAccountBackfillComplete,
                referenceDate: referenceDate,
                calendar: calendar,
                accountStore: accountStore,
                itemStore: itemStore
            )
        }
        return WidgetSnapshot(
            generatedAt: now,
            today: figures(at: now),
            tomorrowStart: tomorrowStart,
            tomorrow: figures(at: tomorrowStart)
        )
    }

    static func figures(
        goals: [SavingsGoal],
        budget: Budget?,
        transactions: [SpendTransaction],
        isAccountBackfillComplete: Bool,
        referenceDate: Date,
        calendar: Calendar,
        accountStore: LinkedAccountStoring,
        itemStore: LinkedItemStoring
    ) -> WidgetSnapshot.Figures {
        let model = BudgetCalculator.cardModel(
            budget: budget,
            allTransactions: transactions,
            isAccountBackfillComplete: isAccountBackfillComplete,
            referenceDate: referenceDate,
            calendar: calendar
        )

        let savingsSummary = TodayScreenCalculator.summary(
            activeGoals: TodayScreenCalculator.activeGoals(goals, referenceDate: referenceDate, calendar: calendar),
            completedUndismissedGoals: TodayScreenCalculator.completedUndismissedGoals(
                goals, referenceDate: referenceDate, calendar: calendar
            ),
            allTransactions: transactions,
            referenceDate: referenceDate,
            calendar: calendar
        )

        return WidgetSnapshot.Figures(
            budget: budgetSection(model),
            savings: savingsSummary.map(section) ?? .notSet,
            month: monthProgress(
                budget: budget,
                model: model,
                transactions: transactions,
                isAccountBackfillComplete: isAccountBackfillComplete,
                referenceDate: referenceDate,
                calendar: calendar,
                accountStore: accountStore,
                itemStore: itemStore
            )
        )
    }

    private static func budgetSection(_ model: BudgetCalculator.CardModel?) -> WidgetSnapshot.Section {
        guard let model else { return .notSet }
        switch model.state {
        case .syncing: return .message(.syncing)
        case .chooseAccounts: return .message(.chooseAccounts)
        case .active: return model.summary.map(section) ?? .notSet
        }
    }

    private static func section(_ summary: TodayScreenCalculator.Summary) -> WidgetSnapshot.Section {
        .active(remaining: summary.remaining, limit: summary.limit, spentToday: summary.spentToday)
    }

    private static func monthProgress(
        budget: Budget?,
        model: BudgetCalculator.CardModel?,
        transactions: [SpendTransaction],
        isAccountBackfillComplete: Bool,
        referenceDate: Date,
        calendar: Calendar,
        accountStore: LinkedAccountStoring,
        itemStore: LinkedItemStoring
    ) -> WidgetSnapshot.MonthProgress? {
        guard let budget, let model,
              let insights = BudgetSummaryCalculator.insights(
                budget: budget,
                transactions: transactions,
                isAccountBackfillComplete: isAccountBackfillComplete,
                referenceDate: referenceDate,
                accountStore: accountStore,
                itemStore: itemStore,
                summary: model.summary,
                calendar: calendar
              )
        else { return nil }
        return WidgetSnapshot.MonthProgress(
            monthName: monthName(for: referenceDate, calendar: calendar),
            sentence: insights.sentence.text,
            spent: insights.spent,
            monthlyAmount: budget.monthlyAmount
        )
    }

    static func monthName(for date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale ?? .current
        formatter.setLocalizedDateFormatFromTemplate("MMMM")
        return formatter.string(from: date)
    }
}
