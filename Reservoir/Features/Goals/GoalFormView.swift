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

    /// Every existing goal — used only to resolve "currently linked to <other goal>" for
    /// the account-association section below (reservoir-loc.3). `@Query` rather than a
    /// one-shot fetch so the label stays correct if another goal's association changes
    /// while this sheet happens to be open.
    @Query private var allGoals: [SavingsGoal]

    let mode: Mode
    /// Lets call sites keep their own existing XCUITest identifier (e.g. TodayView's
    /// "today.createGoalSheet") for the create flow reached from the empty state, while
    /// the Goals tab's own create entry point can use a distinct one.
    var accessibilityIdentifier: String = "goalForm.sheet"

    /// Constructor-injected (reservoir-loc.3), same DI convention `SettingsView`/
    /// `PlaidServiceLive` use for `LinkedItemStoring` — defaults to the real
    /// `UserDefaults`-backed store so every existing call site
    /// (`GoalFormView(mode:)`/`GoalFormView(mode:accessibilityIdentifier:)`) keeps
    /// compiling unchanged, while tests can substitute a stub.
    private let linkedItemStore: LinkedItemStoring

    @State private var targetAmount: Decimal = 0
    @State private var targetDate: Date
    @State private var startingBalance: Decimal = 0
    @State private var startDate: Date = Calendar.current.startOfDay(for: .now)

    /// All linked Plaid items, loaded once when the sheet appears (reservoir-loc.3) — the
    /// multi-select account-association section below is built from this.
    @State private var linkedItems: [LinkedItem] = []

    /// **Create mode only.** Plain local staging for which linked items should be
    /// associated with the goal once it's created — JP's explicit call (2026-08-01):
    /// the multi-select must be usable during creation, not just edit, but the goal
    /// doesn't exist yet to associate anything against. Toggling this never calls
    /// `GoalAccountAssociationService` — see `createGoal()` for where it's actually
    /// applied, after the goal is confirmed persisted. Untouched, and so risk-free, if
    /// the user cancels out of creation (no `.onDisappear`/side effect reads this
    /// anywhere else).
    @State private var stagedAssociatedItemIDs: Set<String> = []

    @State private var isShowingEditConfirmation = false
    @State private var saveError: String?

    private let referenceDate: Date = .now
    private let calendar: Calendar = .current
    private let logger = Logger(subsystem: "com.reservoir.app", category: "GoalFormView")

    init(
        mode: Mode,
        accessibilityIdentifier: String = "goalForm.sheet",
        linkedItemStore: LinkedItemStoring = LinkedItemStore()
    ) {
        self.mode = mode
        self.accessibilityIdentifier = accessibilityIdentifier
        self.linkedItemStore = linkedItemStore
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

                // Account-association section (reservoir-loc.3), present in both create and
                // edit mode. Always shown — a hint replaces the list when there's nothing to
                // associate (JP, 2026-08-01), rather than hiding the section outright, so a
                // user who hasn't linked anything yet still learns the feature exists.
                Section("Linked accounts") {
                    if linkedItems.isEmpty {
                        Text("Link an account in Settings to associate it with this goal")
                            .foregroundStyle(Color("ReservoirTextSecondary"))
                    } else {
                        ForEach(linkedItems, id: \.itemID) { item in
                            Toggle(isOn: Binding(
                                get: { isAssociated(item) },
                                set: { setAssociated($0, item: item) }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.institutionName)
                                    if let otherGoal = otherGoal(associatedWith: item) {
                                        Text("Currently linked to \(otherGoal.displayName)")
                                            .font(.footnote)
                                            .foregroundStyle(Color("ReservoirTextSecondary"))
                                    }
                                }
                            }
                            .accessibilityIdentifier("goalForm.accountToggle.\(item.itemID)")
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .listRowBackground(Color("ReservoirSurface"))
            .background(Color("ReservoirBackground"))
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
        // Loaded once per sheet presentation, same "load on appear, no ongoing
        // subscription" posture `SettingsView` uses for its own Plaid-backed state —
        // `LinkedItemStore` has no change-notification mechanism to subscribe to, and this
        // sheet is short-lived enough that a stale list (e.g. a new account linked in a
        // second window) isn't a realistic concern.
        .task {
            linkedItems = linkedItemStore.loadAll()
            if case .edit(let goal) = mode {
                stagedAssociatedItemIDs = Set(goal.associatedItemIDs)
            }
        }
    }

    // MARK: - Account association (reservoir-loc.3)

    /// Edit mode reads/writes `goal.associatedItemIDs` directly (the live SwiftData
    /// reference); create mode reads the local `stagedAssociatedItemIDs` staging set —
    /// see that property's doc comment for why. `stagedAssociatedItemIDs` is kept seeded
    /// from `goal.associatedItemIDs` in edit mode too (via `.task` above) purely so this
    /// function has one consistent source to read in create mode; edit mode's `isOn`
    /// binding below reads `goal.associatedItemIDs` directly, never
    /// `stagedAssociatedItemIDs`, so the two can't drift out of sync with each other.
    private func isAssociated(_ item: LinkedItem) -> Bool {
        switch mode {
        case .create:
            return stagedAssociatedItemIDs.contains(item.itemID)
        case .edit(let goal):
            return goal.associatedItemIDs.contains(item.itemID)
        }
    }

    /// Create mode only ever mutates local state — never calls
    /// `GoalAccountAssociationService` — since the goal doesn't exist to associate
    /// anything against yet (see `createGoal()` for where staged selections are actually
    /// applied). Edit mode calls the service inline, immediately, against the
    /// already-persisted `goal`.
    private func setAssociated(_ isOn: Bool, item: LinkedItem) {
        switch mode {
        case .create:
            if isOn {
                stagedAssociatedItemIDs.insert(item.itemID)
            } else {
                stagedAssociatedItemIDs.remove(item.itemID)
            }
        case .edit(let goal):
            if isOn {
                _ = GoalAccountAssociationService.associate(itemID: item.itemID, with: goal, modelContext: modelContext)
            } else {
                _ = GoalAccountAssociationService.dissociate(itemID: item.itemID, modelContext: modelContext)
            }
        }
    }

    /// The goal (if any) `item` is currently associated with, excluding the goal this form
    /// itself represents — in edit mode, an item already tied to *this* goal must not show
    /// its own "currently linked to" label, only a genuinely different goal's.
    private func otherGoal(associatedWith item: LinkedItem) -> SavingsGoal? {
        let candidates: [SavingsGoal]
        if case .edit(let goal) = mode {
            candidates = allGoals.filter { $0.persistentModelID != goal.persistentModelID }
        } else {
            candidates = allGoals
        }
        return GoalAccountAssociationService.associatedGoal(for: item.itemID, in: candidates)
    }

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
            return
        }

        // Only once the goal is confirmed persisted (stable `persistentModelID`) does
        // this apply the staged account associations (reservoir-loc.3) — deliberately a
        // second, separate step, not folded into the `mutate` closure above.
        // `GoalAccountAssociationService.associate` is its own self-contained atomic unit
        // (own fetch, own `saveOrRollback`); composing it into the goal-insert's `mutate`
        // would mean its internal `save()` could commit the not-yet-validated insert as a
        // side effect. Sequencing after success keeps each `save()` owning exactly one
        // invariant.
        for itemID in stagedAssociatedItemIDs {
            let associationError = GoalAccountAssociationService.associate(
                itemID: itemID,
                with: goal,
                modelContext: modelContext
            )
            if associationError != nil {
                // Stop on first failure — don't attempt remaining items, don't roll back
                // items already associated. The goal itself is validly persisted at this
                // point; a partial-association failure here is a real but low-stakes edge
                // case (self-healable from Edit), not worth a second rollback path. Sheet
                // stays open so the user sees this, rather than dismissing on a partial
                // failure.
                saveError = "Goal created, but not all accounts could be linked. Edit the goal to retry."
                return
            }
        }
        dismiss()
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
