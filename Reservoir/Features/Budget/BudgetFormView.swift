import SwiftUI
import SwiftData
import OSLog

/// Create/edit sheet for the app's one monthly budget (reservoir-j8t). Same shape as
/// `GoalFormView`: validation lives in `BudgetValidator`, persistence in `BudgetService`
/// (both pure/unit-tested); this view wires `@State` into them.
struct BudgetFormView: View {
    typealias Mode = EntryMode<Budget>

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    /// All transactions, used only to find the earliest imported row of the selected
    /// accounts (the start-date floor).
    @Query private var transactions: [SpendTransaction]

    let mode: Mode
    var accessibilityIdentifier: String = "budget.createBudgetSheet"
    private let linkedAccountStore: LinkedAccountStoring

    @State private var monthlyAmount: Decimal = 0
    @State private var carriesAcrossMonths = true
    @State private var selectedAccountIDs: Set<String> = []
    @State private var startDate: Date
    @State private var linkedAccounts: [LinkedAccount] = []
    @State private var earliestImportedDate: Date?
    @State private var saveError: String?
    /// Set for the duration of `save()` (and until the sheet dismisses on success) so a
    /// second tap on Save/Create can't run a second write while the first is finishing.
    @State private var isSaving = false

    private let referenceDate: Date = .now
    private let calendar: Calendar = .current
    /// Original selection order, so "Closed account" rows keep a stable order.
    private let initialSelection: [String]

    init(
        mode: Mode,
        accessibilityIdentifier: String = "budget.createBudgetSheet",
        linkedAccountStore: LinkedAccountStoring = LinkedAccountStore()
    ) {
        self.mode = mode
        self.accessibilityIdentifier = accessibilityIdentifier
        self.linkedAccountStore = linkedAccountStore
        switch mode {
        case .create:
            _startDate = State(initialValue: BudgetValidator.defaultStartDate(referenceDate: .now))
            initialSelection = []
        case .edit(let budget):
            _monthlyAmount = State(initialValue: budget.monthlyAmount)
            _carriesAcrossMonths = State(initialValue: budget.carriesAcrossMonths)
            _selectedAccountIDs = State(initialValue: Set(budget.selectedAccountIDs))
            _startDate = State(initialValue: budget.startDate)
            initialSelection = budget.selectedAccountIDs
        }
    }

    private var validation: BudgetValidator.ValidationResult {
        BudgetValidator.validate(
            monthlyAmount: monthlyAmount,
            selectedAccountIDs: selectedAccountIDs,
            startDate: startDate,
            earliestImportedDate: earliestImportedDate,
            referenceDate: referenceDate,
            calendar: calendar
        )
    }

    private var startDateRange: ClosedRange<Date> {
        let floor = BudgetValidator.startDateFloor(
            earliestImportedDate: earliestImportedDate, referenceDate: referenceDate, calendar: calendar
        )
        return floor...max(floor, calendar.startOfDay(for: referenceDate))
    }

    private var pickerGroups: [BudgetAccountService.PickerGroup] {
        BudgetAccountService.pickerGroups(
            linkedAccounts: linkedAccounts,
            selectedAccountIDs: initialSelection + selectedAccountIDs.filter { !initialSelection.contains($0) }.sorted()
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledField(label: "Monthly amount", error: validation.amountError, errorIdentifierPrefix: "budget.form") {
                        TextField("Monthly amount", value: $monthlyAmount, format: .currency(code: "USD"))
                            .keyboardType(.decimalPad)
                            .accessibilityIdentifier("budget.form.monthlyAmount")
                    }
                }

                if linkedAccounts.isEmpty && pickerGroups.isEmpty {
                    Section("Accounts") {
                        Text("Link an account in Settings to track a budget.")
                            .foregroundStyle(Color("ReservoirTextSecondary"))
                            .accessibilityIdentifier("budget.form.noAccounts")
                    }
                }
                ForEach(pickerGroups) { group in
                    Section(group.title) {
                        ForEach(group.rows) { row in
                            Toggle(isOn: binding(for: row.id)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.title)
                                    if let detail = row.detail {
                                        Text(detail)
                                            .font(.footnote)
                                            .foregroundStyle(Color("ReservoirTextSecondary"))
                                    }
                                }
                            }
                            .accessibilityIdentifier("budget.form.account.\(row.id)")
                        }
                    }
                }
                Section {
                    EmptyView()
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if let error = validation.accountsError {
                            Text(error)
                                .foregroundStyle(Color("ReservoirDeficit"))
                                .accessibilityIdentifier("budget.form.error.Accounts")
                        }
                        Text("Pick the accounts you spend from. Skip savings accounts.")
                    }
                }

                Section {
                    Picker("When a month ends", selection: $carriesAcrossMonths) {
                        Text("Carry over").tag(true)
                        Text("Start fresh").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("budget.form.monthEnd")
                } header: {
                    Text("When a month ends")
                } footer: {
                    Text(carriesAcrossMonths
                         ? "Unspent money and overspending roll into next month."
                         : "Every month begins at its daily base amount.")
                }

                Section {
                    LabeledField(label: "Start date", error: validation.startDateError, errorIdentifierPrefix: "budget.form") {
                        DatePicker("Start date", selection: $startDate, in: startDateRange, displayedComponents: .date)
                            .accessibilityIdentifier("budget.form.startDate")
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Spending before this date isn't counted.")
                        if mode.isEdit {
                            Text("Changing these settings recalculates your whole budget as if they had always applied.")
                                .accessibilityIdentifier("budget.form.editFooter")
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .listRowBackground(Color("ReservoirSurface"))
            .background(Color("ReservoirBackground"))
            .navigationTitle(mode.isEdit ? "Edit Budget" : "Monthly Budget")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(mode.isEdit ? "Save" : "Create") { save() }
                        .disabled(!validation.isValid || isSaving)
                        .accessibilityIdentifier("budget.form.submit")
                }
            }
            .saveErrorAlert($saveError)
        }
        .accessibilityIdentifier(accessibilityIdentifier)
        .task {
            linkedAccounts = linkedAccountStore.loadAll()
            refreshEarliestImportedDate()
        }
        // Selecting different accounts can move the start-date floor; recompute it so
        // the validator (and date range) re-evaluate the current start date.
        .onChange(of: selectedAccountIDs) { refreshEarliestImportedDate() }
    }

    private func binding(for accountID: String) -> Binding<Bool> {
        Binding(
            get: { selectedAccountIDs.contains(accountID) },
            set: { isOn in
                if isOn { selectedAccountIDs.insert(accountID) } else { selectedAccountIDs.remove(accountID) }
            }
        )
    }

    private func refreshEarliestImportedDate() {
        earliestImportedDate = BudgetValidator.earliestImportedDate(
            selectedAccountIDs: selectedAccountIDs, transactions: transactions, calendar: calendar
        )
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        let ordered = pickerGroups.flatMap(\.rows).map(\.id).filter(selectedAccountIDs.contains)
        let error: String?
        switch mode {
        case .create:
            error = BudgetService.save(
                monthlyAmount: monthlyAmount,
                startDate: calendar.startOfDay(for: startDate),
                carriesAcrossMonths: carriesAcrossMonths,
                selectedAccountIDs: ordered,
                modelContext: modelContext
            )
        case .edit(let budget):
            error = BudgetService.update(
                budget,
                monthlyAmount: monthlyAmount,
                startDate: calendar.startOfDay(for: startDate),
                carriesAcrossMonths: carriesAcrossMonths,
                selectedAccountIDs: ordered,
                modelContext: modelContext
            )
        }
        if let error {
            saveError = error
            isSaving = false
        } else {
            dismiss()
        }
    }
}
