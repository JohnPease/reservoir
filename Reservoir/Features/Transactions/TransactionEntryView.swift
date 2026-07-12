import SwiftUI
import SwiftData
import OSLog

/// The manual transaction add/edit form (adq.3) — retires `StubSheet`'s "Add Transaction"
/// placeholder. Both `TodayView`'s "Add transaction" button and the Transactions tab's own
/// "+" entry point present this same view (STANDARDS.md §3, no copy-paste of two separate
/// forms); tapping a row in `TransactionsView` also presents it pre-filled for editing.
///
/// All validation and the merchant-match/manual-override/goal-attribution-default logic
/// live in `TransactionEntryValidator`/`MerchantMatcher` (pure, unit-tested); this view
/// only wires its `@State` into those and renders the resulting field errors. Save/
/// rollback plumbing goes through the shared `PersistenceSaveHelper`.
struct TransactionEntryView: View {
    typealias Mode = EntryMode<SpendTransaction>

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(TodayClock.self) private var todayClock

    let mode: Mode
    var accessibilityIdentifier: String = "transactionEntry.sheet"

    @Query(sort: \SavingsGoal.targetDate) private var goals: [SavingsGoal]
    @Query private var merchantRules: [MerchantRule]

    @State private var amount: Decimal = 0
    @State private var date: Date
    @State private var merchantName: String = ""
    @State private var type: TransactionType = .variable
    /// Once the user directly taps the type segmented control, auto-suggestion (driven by
    /// `merchantName` changes) stops overwriting their explicit choice — see
    /// `typeBinding`/`applyAutoSuggestedTypeIfNeeded()`. Always `true` from the start in
    /// edit mode (an existing type is never silently reassigned by a merchant-name
    /// edit), which makes this unsuitable on its own for deciding `isManualOverride` —
    /// see `hasUserInteractedWithTypeControl` for that.
    @State private var hasUserEditedType: Bool
    /// True once the user has directly tapped the type segmented control during *this*
    /// entry/edit session — unlike `hasUserEditedType`, this starts `false` in edit mode
    /// too, so `TransactionEntryValidator.isManualOverride` can tell "user actively chose
    /// a type this session" apart from "type field untouched, preserve existing intent."
    @State private var hasUserInteractedWithTypeControl = false
    @State private var selectedGoal: SavingsGoal?
    @State private var hasConfirmedGoalAttribution: Bool
    @State private var hasInitializedGoalAttribution: Bool
    @State private var saveError: String?

    private let calendar: Calendar = .current
    private let logger = Logger(subsystem: "com.reservoir.app", category: "TransactionEntryView")

    init(mode: Mode, accessibilityIdentifier: String = "transactionEntry.sheet") {
        self.mode = mode
        self.accessibilityIdentifier = accessibilityIdentifier
        switch mode {
        case .create:
            _date = State(initialValue: .now)
            _hasUserEditedType = State(initialValue: false)
            _selectedGoal = State(initialValue: nil)
            _hasConfirmedGoalAttribution = State(initialValue: false)
            _hasInitializedGoalAttribution = State(initialValue: false)
        case .edit(let transaction):
            _amount = State(initialValue: transaction.amount)
            _date = State(initialValue: transaction.date)
            _merchantName = State(initialValue: transaction.merchantName)
            _type = State(initialValue: transaction.type)
            // Editing an existing transaction: never let merchant-name auto-suggest
            // silently reassign an already-set type out from under the user.
            _hasUserEditedType = State(initialValue: true)
            _selectedGoal = State(initialValue: transaction.savingsGoal)
            // Whatever attribution the transaction already has (including nil/
            // Unattributed) is itself a made choice — edit mode never re-requires an
            // explicit confirmation the way create mode does at 2+ active goals.
            _hasConfirmedGoalAttribution = State(initialValue: true)
            _hasInitializedGoalAttribution = State(initialValue: true)
        }
    }

    private var activeGoals: [SavingsGoal] {
        TodayScreenCalculator.activeGoals(goals, referenceDate: todayClock.referenceDate, calendar: calendar)
    }

    private var goalAttributionRequirement: TransactionEntryValidator.GoalAttributionRequirement {
        TransactionEntryValidator.goalAttributionRequirement(activeGoals: activeGoals)
    }

    private var suggestedType: TransactionType? {
        MerchantMatcher.match(rules: merchantRules, merchantName: merchantName)
    }

    private var validation: TransactionEntryValidator.ValidationResult {
        TransactionEntryValidator.validate(
            amount: amount,
            date: date,
            merchantName: merchantName,
            hasConfirmedGoalAttribution: hasConfirmedGoalAttribution,
            referenceDate: todayClock.referenceDate,
            calendar: calendar
        )
    }

    private var typeBinding: Binding<TransactionType> {
        Binding(
            get: { type },
            set: { newValue in
                type = newValue
                hasUserEditedType = true
                hasUserInteractedWithTypeControl = true
            }
        )
    }

    /// The Goal picker's option list: `activeGoals` plus the transaction's currently
    /// attributed goal, if editing one that's since gone inactive (completed/dismissed)
    /// and so dropped out of `activeGoals`. Without this, editing such a transaction
    /// shows the picker with no visible selection even though `selectedGoal`/the
    /// underlying data is intact — the picker must always be able to render the
    /// selection it's initialized with.
    private var pickerGoals: [SavingsGoal] {
        guard case .edit(let transaction) = mode,
              let currentGoal = transaction.savingsGoal,
              !activeGoals.contains(where: { $0.persistentModelID == currentGoal.persistentModelID })
        else {
            return activeGoals
        }
        return activeGoals + [currentGoal]
    }

    private var goalBinding: Binding<SavingsGoal?> {
        Binding(
            get: { selectedGoal },
            set: { newValue in
                selectedGoal = newValue
                hasConfirmedGoalAttribution = true
            }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledField(label: "Amount", error: validation.amountError, errorIdentifierPrefix: "transactionEntry") {
                        TextField("Amount", value: $amount, format: .currency(code: "USD"))
                            .keyboardType(.decimalPad)
                            .accessibilityIdentifier("transactionEntry.amount")
                    }

                    LabeledField(label: "Date", error: validation.dateError, errorIdentifierPrefix: "transactionEntry") {
                        DatePicker("Date", selection: $date, displayedComponents: .date)
                            .accessibilityIdentifier("transactionEntry.date")
                    }

                    LabeledField(label: "Merchant", error: validation.merchantNameError, errorIdentifierPrefix: "transactionEntry") {
                        TextField("Merchant", text: $merchantName)
                            .accessibilityIdentifier("transactionEntry.merchantName")
                            .onChange(of: merchantName) {
                                applyAutoSuggestedTypeIfNeeded()
                            }
                    }

                    Picker("Type", selection: typeBinding) {
                        Text("Variable").tag(TransactionType.variable)
                        Text("Fixed").tag(TransactionType.fixed)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("transactionEntry.type")
                }

                Section("Goal") {
                    Picker("Goal", selection: goalBinding) {
                        Text("Unattributed").tag(SavingsGoal?.none)
                        ForEach(pickerGoals, id: \.persistentModelID) { goal in
                            Text(goal.displayName).tag(SavingsGoal?.some(goal))
                        }
                    }
                    .accessibilityIdentifier("transactionEntry.goalPicker")

                    if let error = validation.goalAttributionError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("transactionEntry.error.Goal")
                    }
                }
            }
            .navigationTitle(mode.isEdit ? "Edit Transaction" : "Add Transaction")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(mode.isEdit ? "Save" : "Add") { save() }
                        .disabled(!validation.isValid)
                        .accessibilityIdentifier("transactionEntry.submit")
                }
            }
            .saveErrorAlert($saveError)
        }
        .accessibilityIdentifier(accessibilityIdentifier)
        .task { initializeGoalAttributionIfNeeded() }
    }

    // MARK: - Goal attribution defaulting

    /// Runs once, only for create mode (edit mode already has a fixed initial
    /// attribution state set in `init`). Applies the sole-active-goal auto-select /
    /// zero-active-goals no-op-confirm / 2+-goals-require-explicit-choice rule.
    private func initializeGoalAttributionIfNeeded() {
        guard !mode.isEdit, !hasInitializedGoalAttribution else { return }
        hasInitializedGoalAttribution = true
        switch goalAttributionRequirement {
        case .autoSelect(let goal):
            selectedGoal = goal
            hasConfirmedGoalAttribution = true
        case .noActiveGoals:
            selectedGoal = nil
            hasConfirmedGoalAttribution = true
        case .explicitChoiceRequired:
            selectedGoal = nil
            hasConfirmedGoalAttribution = false
        }
    }

    // MARK: - Type auto-suggest

    private func applyAutoSuggestedTypeIfNeeded() {
        guard !hasUserEditedType else { return }
        type = suggestedType ?? .variable
    }

    // MARK: - Save

    private func save() {
        let trimmedMerchantName = merchantName.trimmingCharacters(in: .whitespacesAndNewlines)

        switch mode {
        case .create:
            let resolvedIsManualOverride = TransactionEntryValidator.isManualOverride(
                suggestedType: suggestedType,
                chosenType: type,
                hasUserInteractedWithTypeControl: hasUserInteractedWithTypeControl,
                existingIsManualOverride: false
            )
            saveCreate(merchantName: trimmedMerchantName, isManualOverride: resolvedIsManualOverride)
        case .edit(let transaction):
            let resolvedIsManualOverride = TransactionEntryValidator.isManualOverride(
                suggestedType: suggestedType,
                chosenType: type,
                hasUserInteractedWithTypeControl: hasUserInteractedWithTypeControl,
                existingIsManualOverride: transaction.isManualOverride
            )
            saveEdit(transaction, merchantName: trimmedMerchantName, isManualOverride: resolvedIsManualOverride)
        }
    }

    private func saveCreate(merchantName: String, isManualOverride: Bool) {
        let transaction = SpendTransaction(
            amount: amount,
            date: date,
            merchantName: merchantName,
            type: type,
            entryMethod: .manual,
            isManualOverride: isManualOverride,
            savingsGoal: selectedGoal,
            createdAt: .now
        )

        let error = PersistenceSaveHelper.saveOrRollback(
            modelContext: modelContext,
            mutate: { modelContext.insert(transaction) },
            rollback: { modelContext.delete(transaction) },
            logger: logger
        )
        if let error {
            saveError = error
        } else {
            dismiss()
        }
    }

    private func saveEdit(_ transaction: SpendTransaction, merchantName: String, isManualOverride: Bool) {
        let original = (
            amount: transaction.amount,
            date: transaction.date,
            merchantName: transaction.merchantName,
            type: transaction.type,
            isManualOverride: transaction.isManualOverride,
            savingsGoal: transaction.savingsGoal
        )
        let newAmount = amount
        let newDate = date
        let newType = type
        let newGoal = selectedGoal

        let error = PersistenceSaveHelper.saveOrRollback(
            modelContext: modelContext,
            mutate: {
                transaction.amount = newAmount
                transaction.date = newDate
                transaction.merchantName = merchantName
                transaction.type = newType
                transaction.isManualOverride = isManualOverride
                transaction.savingsGoal = newGoal
            },
            rollback: {
                transaction.amount = original.amount
                transaction.date = original.date
                transaction.merchantName = original.merchantName
                transaction.type = original.type
                transaction.isManualOverride = original.isManualOverride
                transaction.savingsGoal = original.savingsGoal
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
