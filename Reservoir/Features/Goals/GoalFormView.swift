import SwiftUI
import SwiftData
import OSLog

/// The real goal creation/edit form (adq.5) — retires `StubSheet`'s "Create a Goal"
/// placeholder. Both `TodayView`'s empty-state "Create a goal" button and the Goals
/// tab's own create entry point present this same view (STANDARDS.md §3, no copy-paste
/// of two separate sheets).
///
/// All validation lives in `GoalFormValidator` (pure, unit-tested); this view only wires
/// its `@State` into that validator and renders the resulting field errors. All
/// save/rollback plumbing goes through `PersistenceSaveHelper`, shared with
/// `GoalsView`'s edit/delete/dismiss flows.
struct GoalFormView: View {
    typealias Mode = EntryMode<SavingsGoal>

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let mode: Mode
    /// Lets call sites keep their own existing XCUITest identifier (e.g. TodayView's
    /// "today.createGoalSheet") for the create flow reached from the empty state, while
    /// the Goals tab's own create entry point can use a distinct one.
    var accessibilityIdentifier: String = "goalForm.sheet"

    @State private var targetAmount: Decimal = 0
    @State private var targetDate: Date
    @State private var startingBalance: Decimal = 0
    @State private var startDate: Date = Calendar.current.startOfDay(for: .now)

    @State private var isShowingEditConfirmation = false
    @State private var saveError: String?

    private let referenceDate: Date = .now
    private let calendar: Calendar = .current
    private let logger = Logger(subsystem: "com.reservoir.app", category: "GoalFormView")

    init(mode: Mode, accessibilityIdentifier: String = "goalForm.sheet") {
        self.mode = mode
        self.accessibilityIdentifier = accessibilityIdentifier
        switch mode {
        case .create:
            _targetDate = State(initialValue: Calendar.current.date(byAdding: .day, value: 30, to: .now) ?? .now)
        case .edit(let goal):
            _targetAmount = State(initialValue: goal.targetAmount)
            _targetDate = State(initialValue: goal.targetDate)
            _startingBalance = State(initialValue: goal.startingBalance)
            _startDate = State(initialValue: goal.startDate)
        }
    }

    private var validation: GoalFormValidator.ValidationResult {
        switch mode {
        case .create:
            return GoalFormValidator.validateCreation(
                targetAmount: targetAmount,
                targetDate: targetDate,
                startingBalance: startingBalance,
                startDate: startDate,
                referenceDate: referenceDate,
                calendar: calendar
            )
        case .edit(let goal):
            return GoalFormValidator.validateEdit(
                targetAmount: targetAmount,
                targetDate: targetDate,
                startingBalance: goal.startingBalance,
                startDate: goal.startDate,
                referenceDate: referenceDate,
                calendar: calendar
            )
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledField(label: "Target amount", error: validation.targetAmountError) {
                        TextField("Target amount", value: $targetAmount, format: .currency(code: "USD"))
                            .keyboardType(.decimalPad)
                            .accessibilityIdentifier("goalForm.targetAmount")
                    }

                    LabeledField(label: "Target date", error: validation.targetDateError) {
                        DatePicker("Target date", selection: $targetDate, displayedComponents: .date)
                            .accessibilityIdentifier("goalForm.targetDate")
                    }
                }

                if mode.isEdit {
                    Section("Fixed at creation") {
                        LabeledContent("Starting balance", value: startingBalance, format: .currency(code: "USD"))
                        LabeledContent("Start date", value: startDate, format: .dateTime.month(.wide).day().year())
                    }
                } else {
                    Section {
                        LabeledField(label: "Starting balance", error: validation.startingBalanceError) {
                            TextField("Starting balance", value: $startingBalance, format: .currency(code: "USD"))
                                .keyboardType(.decimalPad)
                                .accessibilityIdentifier("goalForm.startingBalance")
                        }

                        LabeledField(label: "Start date", error: validation.startDateError) {
                            DatePicker("Start date", selection: $startDate, displayedComponents: .date)
                                .accessibilityIdentifier("goalForm.startDate")
                        }
                    }
                }
            }
            .navigationTitle(mode.isEdit ? "Edit Goal" : "Create a Goal")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(mode.isEdit ? "Save" : "Create") {
                        if mode.isEdit {
                            isShowingEditConfirmation = true
                        } else {
                            createGoal()
                        }
                    }
                    .disabled(!validation.isValid)
                    .accessibilityIdentifier("goalForm.submit")
                }
            }
            .confirmationDialog(
                "Changing your target will reset today's carry-forward balance. Any amount you're ahead or behind will not carry over. Continue?",
                isPresented: $isShowingEditConfirmation,
                titleVisibility: .visible
            ) {
                Button("Continue", role: .destructive) { saveEdit() }
                Button("Cancel", role: .cancel) {}
            }
            .saveErrorAlert($saveError)
        }
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    // MARK: - Actions

    private func createGoal() {
        let dailyBase = DailyLimitCalculator.dailyBase(
            targetAmount: targetAmount,
            startingBalance: startingBalance,
            startDate: startDate,
            targetDate: targetDate,
            calendar: calendar
        )
        let goal = SavingsGoal(
            targetAmount: targetAmount,
            targetDate: targetDate,
            startDate: startDate,
            startingBalance: startingBalance,
            dailyBase: dailyBase,
            lastEditedDate: nil,
            dismissedAt: nil,
            createdAt: .now
        )

        let error = PersistenceSaveHelper.saveOrRollback(
            modelContext: modelContext,
            mutate: { modelContext.insert(goal) },
            rollback: { modelContext.delete(goal) },
            logger: logger
        )
        if let error {
            saveError = error
        } else {
            dismiss()
        }
    }

    private func saveEdit() {
        guard case .edit(let goal) = mode else { return }

        let originalTargetAmount = goal.targetAmount
        let originalTargetDate = goal.targetDate
        let originalLastEditedDate = goal.lastEditedDate
        let newTargetAmount = targetAmount
        let newTargetDate = targetDate

        let error = PersistenceSaveHelper.saveOrRollback(
            modelContext: modelContext,
            mutate: {
                goal.targetAmount = newTargetAmount
                goal.targetDate = newTargetDate
                goal.dailyBase = DailyLimitCalculator.dailyBase(
                    targetAmount: newTargetAmount,
                    startingBalance: goal.startingBalance,
                    startDate: goal.startDate,
                    targetDate: newTargetDate,
                    calendar: calendar
                )
                goal.lastEditedDate = .now
            },
            rollback: {
                goal.targetAmount = originalTargetAmount
                goal.targetDate = originalTargetDate
                goal.dailyBase = DailyLimitCalculator.dailyBase(
                    targetAmount: originalTargetAmount,
                    startingBalance: goal.startingBalance,
                    startDate: goal.startDate,
                    targetDate: originalTargetDate,
                    calendar: calendar
                )
                goal.lastEditedDate = originalLastEditedDate
            },
            logger: logger
        )
        if let error {
            saveError = error
        } else {
            dismiss()
        }
    }
}

// `LabeledField` moved to `Reservoir/Shared/LabeledField.swift` (adq.3) so
// `TransactionEntryView`/`MerchantRuleEntryView` reuse it instead of redefining it
// (STANDARDS.md §3).
