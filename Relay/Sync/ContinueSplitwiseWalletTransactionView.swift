//
//  ContinueSplitwiseWalletTransactionView.swift
//  Relay
//
//  In-app equivalent of AddWalletTransactionToSplitwiseIntent.perform(),
//  reached by tapping a "Continue Adding Transaction" notification (or a
//  draft row in TransactionDraftsView) after that Shortcuts run got
//  interrupted before finishing. Reads/writes the exact same
//  WalletTransactionConfigStore and calls the same SplitwiseExpenseHelper
//  the intent does — the only thing that differs is asking the remaining
//  questions via a SwiftUI form instead of requestValue/requestDisambiguation.
//
//  Unlike the intent, this doesn't replicate auto-match patterns or
//  multi-merchant template linking — creating a template here just links
//  this one merchant, using the description as the template name. Anything
//  fancier can still be set up afterwards in Templates.
//

import SwiftUI
import os

private let logger = Logger(subsystem: "com.octabits.relay", category: "ContinueSplitwiseWalletTransactionView")

struct ContinueSplitwiseWalletTransactionView: View {
    let draft: TransactionDraft

    @State private var splitwiseAuth = SplitwiseAuthService()
    @State private var notAuthenticated = false
    @State private var errorMessage: String?
    @State private var isSubmitting = false
    @State private var showTemplateEditor = false
    @State private var editingTemplateName: String? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var expenseDescription = ""
    @State private var templateChoice: String?
    @State private var availableTemplates: [String] = []

    /// True once the resolved (or matched) template already has a cached
    /// Splitwise friend — false also covers "no template yet", so the
    /// friend picker below is shown whenever this is false, regardless of
    /// `templateResolved`.
    @State private var templateHasFriend = false
    @State private var templateFriendName: String?

    @State private var friends: [SplitwiseFriend] = []
    @State private var selectedFriendId: Int?
    @State private var isLoadingFriends = false

    @State private var splitwiseRuntimeChoice: SplitwiseSplitOption? = .always
    @State private var ownShareText = ""

    private let defaultFriend: SplitwiseDefaultFriend?

    /// Preview/testing seam only — nil (the default) always falls through
    /// to the real Keychain check. Lets `#Preview` render the form itself
    /// instead of the "Not Connected" gate.
    init(draft: TransactionDraft, isAuthenticatedOverride: Bool? = nil) {
        self.draft = draft
        defaultFriend = SplitwiseDefaultFriendStore.load()

        // Resolved synchronously so the form is ready on the very first
        // render. `currentAccessToken` is a plain Keychain read here (no
        // network), unlike YNAB's token check, so even the auth gate can
        // be settled up front instead of behind a `.task`.
        guard case .splitwiseWallet(let merchant, _, _) = draft.payload else { return }

        if let ownShare = draft.ownShare {
            _ownShareText = State(initialValue: String(ownShare))
        }

        let isAuthenticated = isAuthenticatedOverride ?? (SplitwiseAuthService.currentAccessToken != nil)
        guard isAuthenticated else {
            _notAuthenticated = State(initialValue: true)
            return
        }

        let config = WalletTransactionConfigStore.load()
        _availableTemplates = State(initialValue: Array(config.templates.keys))
        
        if let info = config.resolvedMerchantInfo(for: merchant) {
            _templateChoice = State(initialValue: info.templateName)
            _expenseDescription = State(initialValue: info.payeeName)
            let template = config.templates[info.templateName]
            _splitwiseRuntimeChoice = State(initialValue: Self.runtimeChoice(for: template?.splitwiseOption ?? .never))
            if let friend = template?.splitwiseFriend {
                _templateHasFriend = State(initialValue: true)
                _templateFriendName = State(initialValue: friend.fullName)
                _selectedFriendId = State(initialValue: friend.id)
            }
        } else {
            _expenseDescription = State(initialValue: merchant)
        }
    }

    private var resolvedSplitwiseAction: SplitwiseSplitOption {
        splitwiseRuntimeChoice ?? .never
    }

    private static func runtimeChoice(for option: SplitwiseTemplateOption) -> SplitwiseSplitOption? {
        switch option {
        case .always: .always
        case .manual: .manual
        case .never: .never
        case .ask: nil
        }
    }

    private var canSubmit: Bool {
        if expenseDescription.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        if selectedFriendId == nil && defaultFriend == nil { return false }
        if splitwiseRuntimeChoice == nil { return false }
        if resolvedSplitwiseAction == .manual, Double(ownShareText) == nil { return false }
        return true
    }

    var body: some View {
        Group {
            if notAuthenticated {
                NotConnectedView(service: "Splitwise", connect: splitwiseAuth.signIn)
            } else {
                content
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onAuthenticated(splitwiseAuth.isAuthenticated) {
            notAuthenticated = false
            Task { await load() }
        }
    }

    private var content: some View {
        List {
            Section {
                TransactionDraftHeader(amount: draft.formattedAmount, merchant: draft.merchant, startedAt: draft.startedAt)
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.sheetBackgroundColor)

            Section {
                DraftDetailRow(icon: "doc.on.doc", title: "Template") {
                    Menu {
                        Button("Create New") { editingTemplateName = nil; showTemplateEditor = true }
                        if !availableTemplates.isEmpty { Divider() }
                        ForEach(availableTemplates.sorted(), id: \.self) { name in
                            Button(name) { templateChoice = name }
                        }
                    } label: {
                        Text(templateChoice ?? "Select")
                            .foregroundStyle(templateChoice == nil ? Color.accentColor : Color.secondary)
                            .lineLimit(1)
                    }
                }
                .cardRowBackground()

                DraftDetailRow(
                    icon: "text.alignleft",
                    title: "Description",
                    isIncomplete: expenseDescription.trimmingCharacters(in: .whitespaces).isEmpty
                ) {
                    TextField("Description", text: $expenseDescription)
                        .multilineTextAlignment(.trailing)
                        .submitLabel(.done)
                }
                .cardRowBackground()

                SplitwiseFriendPickerRow(
                    resolvedFriendName: templateHasFriend ? templateFriendName : nil,
                    isLoading: isLoadingFriends,
                    friends: friends,
                    selectedFriendId: $selectedFriendId,
                    noneLabel: defaultFriend.map { "Default (\($0.firstName))" } ?? "None",
                    isIncomplete: selectedFriendId == nil && defaultFriend == nil
                )

                SplitwiseSplitPickerRow(
                    choice: $splitwiseRuntimeChoice,
                    isIncomplete: splitwiseRuntimeChoice == nil
                )

                if resolvedSplitwiseAction == .manual {
                    SplitwiseOwnShareRow(ownShareText: $ownShareText, isIncomplete: Double(ownShareText) == nil)
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
                .listRowBackground(Color.sheetBackgroundColor)
            }
        }
        .themedList(background: .sheetBackgroundColor)
        .animation(.default, value: resolvedSplitwiseAction)
        .onChange(of: templateChoice) { _, newTemplate in
            applyTemplate(newTemplate)
        }
        .sheet(isPresented: $showTemplateEditor) {
            NavigationStack {
                TemplateEditView(
                    templateName: editingTemplateName,
                    onSave: { savedName in
                        let config = WalletTransactionConfigStore.load()
                        availableTemplates = Array(config.templates.keys)
                        templateChoice = savedName
                        applyTemplate(savedName)
                        showTemplateEditor = false
                    },
                    onDelete: {
                        showTemplateEditor = false
                    }
                )
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .safeAreaBar(edge: .bottom) {
            BottomBarActionButton(
                title: "Add Expense",
                isLoading: isSubmitting,
                isDisabled: !canSubmit || isSubmitting
            ) {
                Task { await submit() }
            }
        }
    }

    private func applyTemplate(_ name: String?) {
        let config = WalletTransactionConfigStore.load()
        guard let name else {
            withAnimation {
                splitwiseRuntimeChoice = .always
                templateHasFriend = false
                templateFriendName = nil
                selectedFriendId = SplitwiseDefaultFriendStore.load()?.id
            }
            return
        }
        let template = config.templates[name]
        let newFriend = template?.splitwiseFriend
        withAnimation {
            splitwiseRuntimeChoice = Self.runtimeChoice(for: template?.splitwiseOption ?? .never)
            if let newFriend {
                templateHasFriend = true
                selectedFriendId = newFriend.id
            } else {
                templateHasFriend = false
                selectedFriendId = SplitwiseDefaultFriendStore.load()?.id
            }
        }
    }

    private func load() async {
        guard !notAuthenticated else { return }
        await loadFriends()
    }

    private func loadFriends() async {
        guard !templateHasFriend else { return }
        guard let token = SplitwiseAuthService.currentAccessToken else { return }
        if let cached = SplitwiseFriendCacheStore.load() {
            friends = SplitwiseFriendUsageStore.sorted(cached)
        }
        isLoadingFriends = friends.isEmpty
        defer { isLoadingFriends = false }
        do {
            friends = SplitwiseFriendUsageStore.sorted(try await SplitwiseFriendCacheStore.fetch(token: token))
        } catch {
            logger.error("failed to load friends: \(String(describing: error), privacy: .public)")
        }
    }

    private func submit() async {
        guard case .splitwiseWallet(let merchant, let amount, _) = draft.payload else { return }
        guard SplitwiseAuthService.currentAccessToken != nil else {
            notAuthenticated = true
            return
        }
        errorMessage = nil
        isSubmitting = true
        defer { isSubmitting = false }

        var config = WalletTransactionConfigStore.load()
        var configChanged = false

        let trimmedDescription = expenseDescription.trimmingCharacters(in: .whitespaces)
        guard !trimmedDescription.isEmpty else {
            errorMessage = "Description can't be empty."
            return
        }
        let finalDescription = trimmedDescription
        let finalTemplateName = templateChoice ?? trimmedDescription

        let finalFriendId: Int
        let finalFriendFirstName: String
        let finalFriendFullName: String
        if templateHasFriend, let existing = config.templates[finalTemplateName]?.splitwiseFriend {
            finalFriendId = existing.id
            finalFriendFirstName = existing.firstName
            finalFriendFullName = existing.fullName
        } else {
            guard let selectedFriendId, let match = friends.first(where: { $0.id == selectedFriendId }) else {
                errorMessage = "Pick a Splitwise friend."
                return
            }
            finalFriendId = match.id
            finalFriendFirstName = match.firstName
            finalFriendFullName = match.fullName
        }

        if templateChoice == nil {
            // Creating new template
            var template = config.templates[finalTemplateName] ?? WalletTransactionConfig.Template()
            template.splitwiseFriendId = finalFriendId
            template.splitwiseFriendFirstName = finalFriendFirstName
            template.splitwiseFriendFullName = finalFriendFullName
            template.splitwiseOption = switch splitwiseRuntimeChoice {
            case .always: .always
            case .manual: .manual
            case .never, nil: .never
            }
            config.templates[finalTemplateName] = template
            config.merchants[merchant] = WalletTransactionConfig.MerchantInfo(payeeName: finalDescription, templateName: finalTemplateName)
            configChanged = true
        } else if !templateHasFriend {
            // Existing template but no cached friend — save the picked friend
            var template = config.templates[finalTemplateName] ?? WalletTransactionConfig.Template()
            template.splitwiseFriendId = finalFriendId
            template.splitwiseFriendFirstName = finalFriendFirstName
            template.splitwiseFriendFullName = finalFriendFullName
            config.templates[finalTemplateName] = template
            configChanged = true
        }

        if configChanged {
            do {
                try WalletTransactionConfigStore.save(config)
            } catch {
                logger.error("failed to save config: \(String(describing: error), privacy: .public)")
            }
        }

        let action = resolvedSplitwiseAction
        guard action != .never else {
            TransactionDraftGuard.complete(draft.id)
            dismiss()
            return
        }

        var ownShare: Double?
        if action == .manual {
            switch SplitwiseExpenseHelper.parseOwnShare(ownShareText, amount: amount) {
            case .valid(let parsed): ownShare = parsed
            case .invalid(let message):
                errorMessage = message
                return
            }
        }

        do {
            _ = try await SplitwiseExpenseHelper.addExpense(
                amount: amount,
                description: finalDescription,
                friend: SplitwiseFriendEntity(id: finalFriendId, firstName: finalFriendFirstName, fullName: finalFriendFullName),
                ownShare: ownShare
            )
            TransactionDraftGuard.complete(draft.id)
            dismiss()
        } catch {
            errorMessage = SplitwiseIntentError.message(for: error)
        }
    }
}

#Preview {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            NavigationStack {
                ContinueSplitwiseWalletTransactionView(
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
