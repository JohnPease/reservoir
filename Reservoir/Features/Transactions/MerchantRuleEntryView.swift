import SwiftUI
import SwiftData
import OSLog

/// Merchant rule create/edit form (adq.3). On save, this is also where the retroactive
/// retag pass fires (JP decision 2026-07-07): creating or editing a rule such that its
/// `merchantName`/`type` changes immediately retags every existing, non-manually-
/// overridden `SpendTransaction` whose `merchantName` case-insensitively matches. The
/// diff (does this edit even need to retag) and the match/mutation logic live in
/// `MerchantRuleRetagCalculator` (pure, unit-tested); this view combines the rule mutation
/// and the retag mutation into a single `modelContext.save()` via `PersistenceSaveHelper`
/// (adq.3 kickoff check 2 — one atomic save, not two sequential ones).
struct MerchantRuleEntryView: View {
    enum Mode {
        case create
        case edit(MerchantRule)

        var isEdit: Bool {
            if case .edit = self { return true }
            return false
        }
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let mode: Mode
    var accessibilityIdentifier: String = "merchantRuleEntry.sheet"

    @Query private var existingRules: [MerchantRule]
    @Query(
        sort: [
            SortDescriptor(\SpendTransaction.date, order: .reverse),
            SortDescriptor(\SpendTransaction.createdAt, order: .reverse)
        ]
    )
    private var allTransactions: [SpendTransaction]

    @State private var merchantName: String
    /// `nil` represents "no type chosen yet" — required on create, no silent default.
    @State private var type: TransactionType?
    @State private var saveError: String?

    private let logger = Logger(subsystem: "com.reservoir.app", category: "MerchantRuleEntryView")

    init(mode: Mode, accessibilityIdentifier: String = "merchantRuleEntry.sheet") {
        self.mode = mode
        self.accessibilityIdentifier = accessibilityIdentifier
        switch mode {
        case .create:
            _merchantName = State(initialValue: "")
            _type = State(initialValue: nil)
        case .edit(let rule):
            _merchantName = State(initialValue: rule.merchantName)
            _type = State(initialValue: rule.type)
        }
    }

    private var ruleBeingEdited: MerchantRule? {
        if case .edit(let rule) = mode { return rule }
        return nil
    }

    private var validation: MerchantRuleValidator.ValidationResult {
        MerchantRuleValidator.validate(
            merchantName: merchantName,
            type: type,
            existingRules: existingRules,
            excluding: ruleBeingEdited
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                LabeledField(label: "Merchant name", error: validation.merchantNameError, errorIdentifierPrefix: "merchantRuleEntry") {
                    TextField("Merchant name", text: $merchantName)
                        .accessibilityIdentifier("merchantRuleEntry.merchantName")
                }

                Section {
                    Picker("Type", selection: $type) {
                        Text("Choose a type").tag(TransactionType?.none)
                        Text("Variable").tag(TransactionType?.some(.variable))
                        Text("Fixed").tag(TransactionType?.some(.fixed))
                    }
                    .accessibilityIdentifier("merchantRuleEntry.type")

                    if let error = validation.typeError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("merchantRuleEntry.error.Type")
                    }
                }
            }
            .navigationTitle(mode.isEdit ? "Edit Rule" : "New Rule")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(mode.isEdit ? "Save" : "Create") { save() }
                        .disabled(!validation.isValid)
                        .accessibilityIdentifier("merchantRuleEntry.submit")
                }
            }
            .alert(
                "Couldn't save",
                isPresented: Binding(
                    get: { saveError != nil },
                    set: { isPresented in if !isPresented { saveError = nil } }
                ),
                presenting: saveError
            ) { _ in
                Button("OK") { saveError = nil }
            } message: { message in
                Text(message)
            }
        }
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    // MARK: - Save

    private func save() {
        guard let type else { return }
        let trimmedMerchantName = merchantName.trimmingCharacters(in: .whitespacesAndNewlines)

        switch mode {
        case .create:
            saveCreate(merchantName: trimmedMerchantName, type: type)
        case .edit(let rule):
            saveEdit(rule, merchantName: trimmedMerchantName, type: type)
        }
    }

    private func saveCreate(merchantName: String, type: TransactionType) {
        let rule = MerchantRule(merchantName: merchantName, type: type)
        let matchingTransactions = MerchantRuleRetagCalculator.transactionsToRetag(allTransactions, merchantName: merchantName)
        let originalTypes = matchingTransactions.map(\.type)

        let error = PersistenceSaveHelper.saveOrRollback(
            modelContext: modelContext,
            mutate: {
                modelContext.insert(rule)
                MerchantRuleRetagCalculator.applyRetag(to: matchingTransactions, newType: type)
            },
            rollback: {
                modelContext.delete(rule)
                for (transaction, originalType) in zip(matchingTransactions, originalTypes) {
                    transaction.type = originalType
                }
            },
            logger: logger
        )
        if let error {
            saveError = error
        } else {
            dismiss()
        }
    }

    private func saveEdit(_ rule: MerchantRule, merchantName: String, type: TransactionType) {
        let oldMerchantName = rule.merchantName
        let oldType = rule.type
        let shouldRetag = MerchantRuleRetagCalculator.requiresRetag(
            oldMerchantName: oldMerchantName,
            oldType: oldType,
            newMerchantName: merchantName,
            newType: type
        )
        let matchingTransactions = shouldRetag
            ? MerchantRuleRetagCalculator.transactionsToRetag(allTransactions, merchantName: merchantName)
            : []
        let originalTypes = matchingTransactions.map(\.type)

        let error = PersistenceSaveHelper.saveOrRollback(
            modelContext: modelContext,
            mutate: {
                rule.merchantName = merchantName
                rule.type = type
                if shouldRetag {
                    MerchantRuleRetagCalculator.applyRetag(to: matchingTransactions, newType: type)
                }
            },
            rollback: {
                rule.merchantName = oldMerchantName
                rule.type = oldType
                for (transaction, originalType) in zip(matchingTransactions, originalTypes) {
                    transaction.type = originalType
                }
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
