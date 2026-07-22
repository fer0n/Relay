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
    @State private var isKeyboardVisible = false
    @FocusState private var isAmountFocused: Bool
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
                TemplatePickerRow(templates: model.availableTemplates, choice: $model.templateChoice) {
                    editingTemplateName = nil
                    showTemplateEditor = true
                }

                PayeeFieldRow(
                    title: model.mode == .ynab ? "Payee" : "Description",
                    placeholder: model.mode == .ynab ? "Payee Name" : "Description",
                    text: $model.payeeText,
                    suggestedNames: model.suggestedPayeeNames,
                    showsLinkToTemplate: model.showsLinkToTemplate,
                    linkToTemplateName: model.linkToTemplateName,
                    onLinkToTemplate: model.linkPayeeToTemplate
                )

                if model.mode == .ynab {
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
                    // Splitwise-primary: friend/split/share live alongside
                    // the description since they *are* the transaction.
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
        .safeAreaBar(edge: .bottom) {
            // While the keyboard is up, the button is only shown once the
            // form is actually submittable — otherwise it'd just be sitting
            // there disabled, chasing the keyboard up the screen for no
            // reason. Once canSubmit flips true it animates in immediately,
            // keyboard or not.
            if model.canSubmit || !isKeyboardVisible {
                BottomBarActionButton(
                    title: model.mode == .ynab ? "Add Transaction" : "Add Expense",
                    isLoading: model.isSubmitting,
                    isDisabled: !model.canSubmit || model.isSubmitting
                ) {
                    Task { if await model.submit() { dismiss() } }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.default, value: model.canSubmit)
        .animation(.default, value: isKeyboardVisible)
        .onKeyboardVisibilityChange($isKeyboardVisible)
    }

    // MARK: - Rows

    private var manualAmountField: some View {
        TextField("0", text: $model.amountText)
            .keyboardType(.decimalPad)
            .multilineTextAlignment(.center)
            .foregroundStyle(Color.foregroundColor)
            .fontWeight(.heavy)
            .font(.system(size: 50))
            .minimumScaleFactor(0.5)
            .frame(maxWidth: .infinity)
            .dismissButtonToolbar(isFocused: $isAmountFocused)
            .onAppear { isAmountFocused = true }
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
