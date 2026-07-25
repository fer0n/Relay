//
//  ContinueWalletTransactionView.swift
//  Relay
//
//  In-app equivalent of AddWalletTransactionToYNABIntent.perform() and
//  AddWalletTransactionToSplitwiseIntent.perform(), reached by tapping a
//  "Continue Adding Transaction" notification (or a draft row in
//  TransactionDraftsView) after a Shortcuts run got interrupted before
//  finishing. A single unified form that handles both wallet draft kinds —
//  a `.ynabWallet` draft shows the YNAB fields (payee, account, category)
//  plus an optional Split section, while a `.splitwiseWallet` draft (the
//  leftover-split half of a YNAB run, or a Splitwise-primary run) hides the
//  YNAB-only fields and shows just the split.
//
//  All the field state and load/submit work lives in
//  ContinueWalletTransactionModel; this view is just the SwiftUI layout that
//  binds to it. Unlike the intents, this doesn't replicate auto-match
//  patterns or multi-merchant template linking — creating a template here
//  just links this one merchant, using the payee/description as the template
//  name. Anything fancier can still be set up afterwards in Templates.
//

import SwiftUI

struct ContinueWalletTransactionView: View {
    @State private var model: ContinueWalletTransactionModel
    @State private var showTemplateEditor = false
    @State private var editingTemplateName: String?
    @Environment(\.dismiss) private var dismiss

    /// Called when the user taps "Discard" — typically deletes the draft and
    /// dismisses. Nil hides the section entirely (e.g. manual entries).
    let onDiscard: (() -> Void)?

    init(draft: TransactionDraft, isManual: Bool = false, prefill: TransactionHistoryEntry? = nil, onDiscard: (() -> Void)? = nil, isAuthenticatedOverride: Bool? = nil) {
        _model = State(initialValue: ContinueWalletTransactionModel(draft: draft, isManual: isManual, prefill: prefill, isAuthenticatedOverride: isAuthenticatedOverride))
        self.onDiscard = onDiscard
    }

    var body: some View {
        Group {
            if model.isManual ? !model.isModeAuthenticated : model.notAuthenticated {
                switch model.mode {
                case .ynab: NotConnectedView(service: "YNAB", connect: model.ynabAuth.signIn)
                case .splitwise: NotConnectedView(service: "Splitwise", connect: model.splitwiseAuth.signIn)
                }
            } else {
                content
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.isManual {
                ToolbarItem(placement: .principal) {
                    // Only a real choice when both services are connected —
                    // with just one connected, the other option in the menu
                    // would just lead to a "Connect ___" dead end, so show a
                    // plain (non-interactive) label naming the only usable
                    // service instead.
                    if model.ynabAuth.isAuthenticated, model.splitwiseAuth.isAuthenticated {
                        Menu {
                            Picker("Type", selection: manualModeBinding) {
                                Text("Both").tag(ContinueWalletTransactionModel.Mode.ynab)
                                Text("Splitwise").tag(ContinueWalletTransactionModel.Mode.splitwise)
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(model.mode == .ynab ? "Both" : "Splitwise")
                                    .fontWeight(.semibold)
                                Image(systemName: "chevron.down")
                                    .font(.caption2)
                            }
                            .foregroundStyle(Color.foregroundColor)
                        }
                    } else {
                        Text(model.mode == .ynab ? "YNAB" : "Splitwise")
                            .fontWeight(.semibold)
                            .foregroundStyle(Color.foregroundColor)
                    }
                }
            }
        }
        .task { await model.load() }
        .onAuthenticated(model.mode == .ynab ? model.ynabAuth.isAuthenticated : model.splitwiseAuth.isAuthenticated) {
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

    private var splitwiseChoiceBinding: Binding<SplitwiseSplitOption?> {
        Binding(get: { model.splitwiseRuntimeChoice }, set: { model.setSplitwiseRuntimeChoice($0) })
    }

    private var content: some View {
        List {
            Section {
                if model.isManual {
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
                } else {
                    // Splitwise-primary: a shortcut draft splits the one field
                    // into Payee (the merchant's clean name, stored on the
                    // merchant→template mapping) and Description (the expense
                    // text, defaulting to the payee). A manual entry has no
                    // merchant to name, so it keeps the single Description
                    // field. Friend/split/share follow since they *are* the
                    // transaction.
                    if model.isManual {
                        payeeTextRow(title: "Description", placeholder: String(localized: "Description"))
                    } else {
                        payeeTextRow(title: "Payee", placeholder: model.draft.merchant, allowsEmpty: true)
                        descriptionRow
                    }
                    friendRow
                    splitPickerRow
                    if model.resolvedSplitwiseAction == .manual {
                        ownShareRow
                    }
                }
            }

            if model.mode == .ynab, model.splitwiseAuth.isAuthenticated {
                Section("Split") {
                    splitPickerRow
                    if model.resolvedSplitwiseAction != .never {
                        friendRow
                    }
                    if model.resolvedSplitwiseAction == .manual {
                        ownShareRow
                    }
                }
            }

            if let errorMessage = model.errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
                .listRowBackground(Color.sheetBackgroundColor)
            }

            if let onDiscard {
                DiscardSection(confirmationTitle: "Discard this draft?", onConfirm: onDiscard)
            }
        }
        .themedList(background: .sheetBackgroundColor)
        .animation(.default, value: model.resolvedSplitwiseAction)
        .onChange(of: model.templateChoice) { _, newTemplate in
            model.applyTemplate(newTemplate)
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
            title: model.mode == .ynab ? "Add Transaction" : "Add Expense",
            isLoading: model.isSubmitting,
            isDisabled: !model.canSubmit || model.isSubmitting
        ) {
            Task { if await model.submit() { dismiss() } }
        }
    }

    // MARK: - Rows

    /// Uses `InstantFocusTextField` rather than a plain `TextField` focused in
    /// `.onAppear`: focusing through `@FocusState` doesn't raise the keyboard
    /// until the sheet's presentation transition has committed, which is a
    /// visible delay on every open. See that file for the details.
    private var manualAmountField: some View {
        InstantFocusTextField(text: $model.amountText, placeholder: "0")
            .frame(maxWidth: .infinity)
            .frame(height: 60)
    }

    /// The `payeeText`-bound text field with its auto-match suggestion bar —
    /// the YNAB payee, the Splitwise Payee, or a manual Splitwise entry's
    /// single Description field. `allowsEmpty` lets the shortcut Splitwise
    /// Payee fall back to its merchant placeholder without being flagged.
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

    /// The Splitwise expense Description field (shortcut drafts only). No
    /// suggestion bar — payee-name autocomplete belongs to the Payee field
    /// above it — and its placeholder mirrors the effective payee so leaving
    /// it blank files the expense under that name.
    private var descriptionRow: some View {
        PayeeFieldRow(
            title: "Description",
            placeholder: model.splitwisePayeeName,
            text: $model.descriptionText,
            suggestedNames: [],
            showsLinkToTemplate: false,
            linkToTemplateName: "",
            onLinkToTemplate: {},
            allowsEmpty: true
        )
    }

    private var friendRow: some View {
        SplitwiseFriendPickerRow(
            resolvedFriendName: model.resolvedFriendName,
            isLoading: model.isLoadingFriends,
            friends: model.friends,
            selectedFriendId: $model.selectedFriendId,
            noneLabel: model.friendNoneLabel,
            isIncomplete: model.friendRowIsIncomplete
        )
    }

    private var splitPickerRow: some View {
        SplitwiseSplitPickerRow(
            choice: splitwiseChoiceBinding,
            isIncomplete: model.splitwiseRuntimeChoice == nil
        )
    }

    private var ownShareRow: some View {
        SplitwiseOwnShareRow(ownShareText: $model.ownShareText, isIncomplete: Double(model.ownShareText) == nil)
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

#Preview("Splitwise Draft") {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            NavigationStack {
                ContinueWalletTransactionView(
                    draft: TransactionDraft(
                        id: UUID(),
                        startedAt: Date().addingTimeInterval(-3600),
                        payload: .splitwiseWallet(merchant: "Grocery Store", amount: 32.10)
                    ),
                    isAuthenticatedOverride: true
                )
            }
        }
}
