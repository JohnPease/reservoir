import Foundation
import SwiftData

#if DEBUG
/// Named, deterministic SwiftData fixtures the app seeds into an in-memory store when
/// launched under XCUITest with `UITEST_SCENARIO` set — see `ReservoirApp`. Debug-only:
/// this scaffolding never ships in a Release/sideload build.
enum UITestScenario: String {
    /// No goals at all — the Today screen's "no active goal" empty state.
    case emptyGoal
    /// One active goal with a mix of variable and fixed transactions — the Today
    /// screen's normal state.
    case normal
    /// One goal whose `targetDate` has already passed and hasn't been dismissed yet —
    /// the Today screen's completion banner.
    case completedGoalBanner
    /// Same as `completedGoalBanner`, plus an orphaned (no `savingsGoal`) transaction
    /// dated today — regression coverage for review finding 2: today's spend must still
    /// be visible even though there's no active goal, and the empty-state prompt must
    /// not render underneath the completion banner.
    case completedGoalBannerWithOrphanedSpend
    /// A goal whose `targetDate` has already passed and hasn't been dismissed yet, but
    /// whose cumulative carry-forward balance is negative through `targetDate` — the
    /// "not met" completion banner variant (reservoir-4za).
    case completedGoalBannerNotMet

    static var current: UITestScenario? {
        ProcessInfo.processInfo.environment["UITEST_SCENARIO"].flatMap(UITestScenario.init(rawValue:))
    }

    /// Seeds `context` with this scenario's fixtures and saves.
    func seed(into context: ModelContext) {
        switch self {
        case .emptyGoal:
            break

        case .normal:
            let goal = SavingsGoal(
                targetAmount: 1000,
                targetDate: Calendar.current.date(byAdding: .day, value: 10, to: .now)!,
                startDate: Calendar.current.date(byAdding: .day, value: -5, to: .now)!,
                startingBalance: 100,
                dailyBase: 30
            )
            context.insert(goal)
            context.insert(SpendTransaction(
                amount: 12.50,
                date: .now,
                merchantName: "Coffee Shop",
                type: .variable,
                entryMethod: .manual,
                savingsGoal: goal
            ))
            context.insert(SpendTransaction(
                amount: 45,
                date: .now,
                merchantName: "Rent",
                type: .fixed,
                entryMethod: .manual,
                savingsGoal: goal
            ))

        case .completedGoalBanner:
            // No spend entries recorded at all, so cumulative carry-forward through
            // targetDate is a full 30 days' worth of dailyBase — comfortably >= 0, i.e.
            // the "met" banner variant (reservoir-4za).
            let goal = SavingsGoal(
                targetAmount: 500,
                targetDate: Calendar.current.date(byAdding: .day, value: -1, to: .now)!,
                startDate: Calendar.current.date(byAdding: .day, value: -30, to: .now)!,
                startingBalance: 0,
                dailyBase: 20
            )
            context.insert(goal)

        case .completedGoalBannerNotMet:
            // A single, large overspend entry that dwarfs the rest of the goal's
            // lifetime underspend, leaving cumulative carry-forward negative through
            // targetDate — the "not met" banner variant (reservoir-4za).
            let goal = SavingsGoal(
                targetAmount: 500,
                targetDate: Calendar.current.date(byAdding: .day, value: -1, to: .now)!,
                startDate: Calendar.current.date(byAdding: .day, value: -30, to: .now)!,
                startingBalance: 0,
                dailyBase: 20
            )
            context.insert(goal)
            context.insert(SpendTransaction(
                amount: 5000,
                date: Calendar.current.date(byAdding: .day, value: -29, to: .now)!,
                merchantName: "Big Overspend",
                type: .variable,
                entryMethod: .manual,
                savingsGoal: goal
            ))

        case .completedGoalBannerWithOrphanedSpend:
            let goal = SavingsGoal(
                targetAmount: 500,
                targetDate: Calendar.current.date(byAdding: .day, value: -1, to: .now)!,
                startDate: Calendar.current.date(byAdding: .day, value: -30, to: .now)!,
                startingBalance: 0,
                dailyBase: 20
            )
            context.insert(goal)
            context.insert(SpendTransaction(
                amount: 20,
                date: .now,
                merchantName: "Orphaned Purchase",
                type: .variable,
                entryMethod: .manual,
                savingsGoal: nil
            ))
        }

        try? context.save()
    }
}
#endif
