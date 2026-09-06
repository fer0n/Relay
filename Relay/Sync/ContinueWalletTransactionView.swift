//
//  ContinueWalletTransactionView.swift
//  Relay
//
//  In-app equivalent of the wallet intents' perform(), reached from a draft
//  reminder after a Shortcuts run was interrupted. One form for both draft
//  kinds: a `.ynabWallet` draft shows the YNAB fields plus an optional Split
//  section, a `.ledgerWallet` one shows just the split.
//
//  All field state and load/submit work lives in
//  ContinueWalletTransactionModel; this is just the layout that binds to it.
//  Creating a template here links only this one merchant, named after the
//  payee — auto-match patterns and the rest are set up in Templates.
//

import SwiftUI

struct ContinueWalletTransactionView: View {
    @State private var model: ContinueWalletTransactionModel
    @State private var showTemplateEditor = false
    @State private var editingTemplateName: String?
    @State private var isKeyboardVisible = false
    @Environment(\.dismiss) private var dismiss

    /// Nil hides the Discard section entirely, e.g. for manual entries.
    let onDiscard: (() -> Void)?

    init(draft: TransactionDraft, isManual: Bool = false, prefill: TransactionHistoryEntry? = nil, onDiscard: (() -> Void)? = nil, isAuthenticatedOverride: Bool? = nil, friendOverride: SplitTargetEntity? = nil) {
        _model = State(initialValue: ContinueWalletTransactionModel(draft: draft, isManual: isManual, prefill: prefill, isAuthenticatedOverride: isAuthenticatedOverride, friendOverride: friendOverride))
        self.onDiscard = onDiscard
    }

    var body: some View {
        Group {
            if model.isManual ? !model.isModeAuthenticated : model.notAuthenticated {
                switch model.mode {
                case .ynab: NotConnectedView(service: "YNAB", connect: model.ynabAuth.signIn)
                case .ledger: EmptyView()
                }
            } else {
                content
            }
        }
        // The Payee field's suggestion bar sits in a keyboard toolbar, which has
        // no width of its own to lay out against — see `keyboardBarWidthSource`.
        .keyboardBarWidthSource()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.isManual {
                ToolbarItem(placement: .principal) {
                    // With only one usable the menu's other option would only
                    // lead to a dead end, so show a plain label naming the
                    // usable one instead.
                    if model.ynabAuth.isAuthenticated, model.canSplit {
                        // There are only two modes, so a tap flips to the other
                        // one; the menu is there for whoever expects to pick.
                        Menu {
                            Picker("Type", selection: manualModeBinding) {
                                Text("Both").tag(ContinueWalletTransactionModel.Mode.ynab)
                                Text("Split Only").tag(ContinueWalletTransactionModel.Mode.ledger)
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(model.mode == .ynab ? "Both" : "Split Only")
                                    .fontWeight(.semibold)
                                Image(systemName: "chevron.down")
                                    .font(.caption2)
                            }
                            .foregroundStyle(Color.foregroundColor)
                        } primaryAction: {
                            model.setManualMode(model.manualMode == .ynab ? .ledger : .ynab)
                        }
                    } else {
                        Text(model.mode == .ynab ? "YNAB" : "Split")
                            .fontWeight(.semibold)
                            .foregroundStyle(Color.foregroundColor)
                    }
                }
            }
        }
        .task { await model.load() }
        .onAuthenticated(model.ynabAuth.isAuthenticated) {
            model.notAuthenticated = false
            Task { await model.load() }
        }
    }

    private var manualModeBinding: Binding<ContinueWalletTransactionModel.Mode> {
        Binding(get: { model.manualMode }, set: { model.setManualMode($0) })
    }

    private var accountBinding: Binding<String?> {
        Binding(get: { model.selectedAccountId }, set: { model.setSelectedAccountId($0) })
    }

    private var splitChoiceBinding: Binding<SplitChoice?> {
        Binding(get: { model.splitRuntimeChoice }, set: { model.setSplitRuntimeChoice($0) })
    }

    private var content: some View {
        List {
            Section {
                if model.amountIsEditable {
                    manualAmountField
                } else {
                    TransactionDraftHeader(amount: model.draft.formattedAmount, merchant: model.draft.merchant, startedAt: model.draft.startedAt)
                }
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.sheetBackgroundColor)

            Section {
                TemplatePickerRow(
                    templates: model.availableTemplates,
                    choice: $model.templateChoice,
                    onCreateNew: {
                        editingTemplateName = nil
                        showTemplateEditor = true
                    },
                    isIncomplete: model.mode == .ynab && model.templateChoice == nil
                )

                if model.mode == .ynab {
                    payeeTextRow(title: "Payee", placeholder: String(localized: "Payee Name"))
                    AccountPickerRow(
                        cardName: model.cardName,
                        isResolved: model.accountResolved,
                        isLoading: model.isLoadingAccounts,
                        accounts: model.accounts,
                        selection: accountBinding
                    )
                    CategoryPickerRow(
                        isLoading: model.isLoadingCategories,
                        categories: model.categories,
                        selection: $model.selectedCategoryId
                    )
                    MemoFieldRow(text: $model.memoText)
                } else {
                    // A shortcut draft splits the one field into Payee (the
                    // merchant's clean name, stored on the merchant→template
                    // mapping) and Description (the expense text). A manual entry
                    // has no merchant to name, so it keeps the single field.
                    if model.isManual {
                        payeeTextRow(title: "Description", placeholder: String(localized: "Description"))
                    } else {
                        payeeTextRow(title: "Payee", placeholder: model.draft.merchant, allowsEmpty: true)
                        descriptionRow
                    }
                    splitDestinationRow
                    friendRow
                    splitPickerRow
                    splitDetailRows
                }
            }

            // A ledger is reason enough to offer the Split section.
            if model.mode == .ynab, model.canSplit {
                Section("Split") {
                    splitPickerRow
                    if model.resolvedSplitAction != .never {
                        splitDestinationRow
                        friendRow
                    }
                    splitDetailRows
                }
            }

            if let errorMessage = model.errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
                .listRowBackground(Color.sheetBackgroundColor)
            }

            // The pinned button steps aside for the keyboard, so while typing
            // the form carries its own copy at the end of the list rather than
            // making every entry dismiss the keyboard first.
            if isKeyboardVisible {
                Section {
                    submitButton
                        .frame(maxWidth: .infinity)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            if let onDiscard {
                DiscardSection(confirmationTitle: "Discard this draft?", onConfirm: onDiscard)
            }
        }
        .onKeyboardVisibilityChange($isKeyboardVisible)
        .themedList(background: .sheetBackgroundColor)
        .animation(.default, value: model.resolvedSplitAction)
        .onChange(of: model.templateChoice) { _, newTemplate in
            model.applyTemplate(newTemplate)
        }
        // Description mirrors Payee until typed into directly. `initial: true`
        // also seeds it on first appearance, covering a resolved-merchant draft
        // that opens with Payee already filled in.
        .onChange(of: model.payeeText, initial: true) { _, newValue in
            guard !model.isDescriptionManuallyEdited else { return }
            model.descriptionText = newValue
        }
        .onChange(of: model.descriptionText) { _, newValue in
            guard newValue != model.payeeText else { return }
            model.isDescriptionManuallyEdited = true
        }
        .sheet(isPresented: $showTemplateEditor) {
            NavigationStack {
                TemplateEditView(
                    templateName: editingTemplateName,
                    onSave: { savedName in
                        model.templateSaved(savedName)
                        showTemplateEditor = false
                    },
                    onDelete: {
                        showTemplateEditor = false
                    }
                )
                .navigationBarTitleDisplayMode(.inline)
            }
            .presentationBackground(Color.sheetBackgroundColor)
        }
        .bottomBarActionButton(
            isPresented: true,
            title: submitTitle,
            isLoading: model.isSubmitting,
            isDisabled: submitIsDisabled,
            action: submit
        )
    }

    private var submitTitle: LocalizedStringKey {
        model.mode == .ynab ? "Add Transaction" : "Add Expense"
    }

    private var submitIsDisabled: Bool {
        !model.canSubmit || model.isSubmitting
    }

    private var submitButton: some View {
        BottomBarActionButton(
            title: submitTitle,
            isLoading: model.isSubmitting,
            isDisabled: submitIsDisabled,
            action: submit
        )
    }

    private func submit() {
        Task { if await model.submit() { dismiss() } }
    }

    // MARK: - Rows

    /// Uses `InstantFocusTextField` rather than `@FocusState`, which doesn't raise
    /// the keyboard until the sheet's presentation transition has committed — a
    /// visible delay on every open. A re-add skips the automatic focus, since its
    /// amount is already filled in and the form is there to be reviewed.
    private var manualAmountField: some View {
        InstantFocusTextField(text: $model.amountText, placeholder: "0", autoFocuses: !model.isPrefilled)
            .frame(maxWidth: .infinity)
            .frame(height: 60)
    }

    /// The `payeeText`-bound field with its auto-match suggestion bar.
    /// `allowsEmpty` lets a shortcut draft's Payee fall back to its merchant
    /// placeholder without being flagged.
    private func payeeTextRow(title: LocalizedStringKey, placeholder: String, allowsEmpty: Bool = false) -> some View {
        PayeeFieldRow(
            title: title,
            placeholder: placeholder,
            text: $model.payeeText,
            suggestedNames: model.suggestedPayeeNames,
            showsLinkToTemplate: model.showsLinkToTemplate,
            linkToTemplateName: model.linkToTemplateName,
            onLinkToTemplate: model.linkPayeeToTemplate,
            allowsEmpty: allowsEmpty
        )
    }

    /// Shortcut drafts only. No suggestion bar — payee-name autocomplete belongs
    /// to the Payee field above it.
    private var descriptionRow: some View {
        PayeeFieldRow(
            title: "Description",
            placeholder: model.splitPayeeName,
            text: $model.descriptionText,
            suggestedNames: [],
            showsLinkToTemplate: false,
            linkToTemplateName: "",
            onLinkToTemplate: {},
            allowsEmpty: true
        )
    }

    /// Only there once there's more than one ledger to choose between.
    @ViewBuilder
    private var splitDestinationRow: some View {
        if model.availableLedgers.count > 1 {
            SplitDestinationRow(
                selectedLedgerName: model.selectedLedger?.name,
                ledgers: model.availableLedgers,
                onSelectLedger: model.selectLedger
            )
        }
    }

    private var friendRow: some View {
        LedgerParticipantPickerRow(
            ledger: model.selectedLedger,
            selectedIDs: $model.ledgerParticipantIDs,
            isIncomplete: model.friendRowIsIncomplete
        )
    }

    private var splitPickerRow: some View {
        SplitPickerRow(
            choice: splitChoiceBinding,
            isIncomplete: model.splitRuntimeChoice == nil
        )
    }

    /// Whatever the picked split mode still needs typed in: nothing for an even
    /// split, the amount for `.manual`, a weight each for `.shares`.
    @ViewBuilder
    private var splitDetailRows: some View {
        switch model.resolvedSplitAction {
        case .manual:
            OwnShareRow(ownShareText: $model.ownShareText, isIncomplete: Double(model.ownShareText) == nil)
        case .shares:
            ShareWeightRow(
                name: String(localized: "You"),
                amountText: model.ownShareAmountText,
                weight: $model.ownWeightText
            )
            ForEach(model.splitParticipants) { participant in
                ShareWeightRow(
                    name: participant.firstName,
                    amountText: model.shareAmountText(for: participant.id),
                    weight: Binding(
                        get: { model.weightText(for: participant.id) },
                        set: { model.setWeightText($0, for: participant.id) }
                    )
                )
            }
        case .always, .never:
            EmptyView()
        }
    }
}

#Preview("YNAB Draft") {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            NavigationStack {
                ContinueWalletTransactionView(
                    draft: TransactionDraft(
                        id: UUID(),
                        startedAt: Date().addingTimeInterval(-3600),
                        payload: .ynabWallet(merchant: "Coffee Shop", amount: 4.50, card: "Visa")
                    ),
                    isAuthenticatedOverride: true
                )
            }
        }
}

#Preview("Ledger Draft") {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            NavigationStack {
                ContinueWalletTransactionView(
                    draft: TransactionDraft(
                        id: UUID(),
                        startedAt: Date().addingTimeInterval(-3600),
                        payload: .ledgerWallet(merchant: "Grocery Store", amount: 32.10)
                    ),
                    isAuthenticatedOverride: true
                )
            }
        }
}
