//
//  ContinueYNABWalletTransactionView.swift
//  Relay
//
//  In-app equivalent of AddWalletTransactionToYNABIntent.perform(), reached
//  by tapping a "Continue Adding Transaction" notification (or a draft row
//  in TransactionDraftsView) after that Shortcuts run got interrupted
//  before finishing. Reads/writes the exact same WalletTransactionConfigStore
//  and calls the same PendingSync/SplitwiseExpenseHelper the intent does —
//  the only thing that differs is asking the remaining questions via a
//  SwiftUI form instead of requestValue/requestDisambiguation.
//
//  Unlike the intent, this doesn't replicate auto-match patterns or
//  multi-merchant template linking — creating a template here just links
//  this one merchant, using the payee name as the template name. Anything
//  fancier can still be set up afterwards in Templates.
//

import SwiftUI
import os

private let logger = Logger(subsystem: "com.octabits.relay", category: "ContinueYNABWalletTransactionView")

struct ContinueYNABWalletTransactionView: View {
    let draft: TransactionDraft

    @State private var ynabAuth = YNABAuthService()
    @State private var splitwiseAuth = SplitwiseAuthService()
    @State private var notAuthenticated = false
    @State private var errorMessage: String?
    @State private var isSubmitting = false
    @State private var showTemplateEditor = false
    @State private var editingTemplateName: String? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var payeeName = ""
    @State private var templateChoice: String?
    @State private var availableTemplates: [String] = []
    @State private var categories: [YNABCategory] = []
    @State private var selectedCategoryId: String?
    @State private var isLoadingCategories = false

    @State private var accountResolved = false
    @State private var accounts: [YNABAccount] = []
    @State private var selectedAccountId: String?
    @State private var isLoadingAccounts = false

    @State private var splitwiseRuntimeChoice: SplitwiseSplitOption? = .never
    @State private var friends: [SplitwiseFriend] = []
    @State private var selectedFriendId: Int?
    @State private var isLoadingFriends = false
    @State private var ownShareText = ""

    /// True once the resolved template already has its own cached
    /// Splitwise friend — that takes precedence over the app-wide default
    /// (SplitwiseDefaultFriendStore), matching AddWalletTransactionToYNABIntent's
    /// resolution order, and shown read-only rather than re-offered as a
    /// choice. Kept as a full entity (not just an id) so submit() can use it
    /// directly instead of requiring a match in the (possibly still-loading,
    /// or since-changed) fetched `friends` list.
    @State private var templateHasFriend = false
    @State private var templateFriend: SplitwiseFriendEntity?

    private let defaultFriend: SplitwiseDefaultFriend?

    /// Preview/testing seam only — nil (the default) always falls through
    /// to the real Keychain check. Lets `#Preview` render the form itself
    /// instead of racing the async "Not Connected" gate.
    let isAuthenticatedOverride: Bool?

    init(draft: TransactionDraft, isAuthenticatedOverride: Bool? = nil) {
        self.draft = draft
        self.isAuthenticatedOverride = isAuthenticatedOverride
        defaultFriend = SplitwiseDefaultFriendStore.load()

        // Resolved synchronously (local disk reads only) so the form's
        // payee/category/account defaults are in place on the very first
        // render — no need to wait on a `.task` for this part.
        guard case .ynabWallet(let merchant, _, let card) = draft.payload else { return }

        let config = WalletTransactionConfigStore.load()
        _availableTemplates = State(initialValue: Array(config.templates.keys))
        
        var resolvedTemplateFriend: (id: Int, firstName: String, fullName: String)?
        if let info = config.resolvedMerchantInfo(for: merchant) {
            _templateChoice = State(initialValue: info.templateName)
            _payeeName = State(initialValue: info.payeeName)
            let template = config.templates[info.templateName]
            _selectedCategoryId = State(initialValue: template?.categoryId)
            _splitwiseRuntimeChoice = State(initialValue: Self.runtimeChoice(for: template?.splitwiseOption ?? .never))
            resolvedTemplateFriend = template?.splitwiseFriend
        } else {
            _payeeName = State(initialValue: merchant)
        }

        if let accountId = config.cards[card] {
            _accountResolved = State(initialValue: true)
            _selectedAccountId = State(initialValue: accountId)
        }

        if let resolvedTemplateFriend {
            _templateHasFriend = State(initialValue: true)
            _templateFriend = State(initialValue: SplitwiseFriendEntity(id: resolvedTemplateFriend.id, firstName: resolvedTemplateFriend.firstName, fullName: resolvedTemplateFriend.fullName))
            _selectedFriendId = State(initialValue: resolvedTemplateFriend.id)
        } else if let defaultFriend = SplitwiseDefaultFriendStore.load() {
            _selectedFriendId = State(initialValue: defaultFriend.id)
        }
    }

    private var cardName: String {
        if case .ynabWallet(_, _, let card) = draft.payload { return card }
        return "Account"
    }

    private var resolvedSplitwiseAction: SplitwiseSplitOption {
        // A template can carry a non-.never split setting from before Splitwise
        // was disconnected — treat as "never split" for this run rather than
        // showing a Splitwise picker/friend field with nothing behind it.
        guard splitwiseAuth.isAuthenticated else { return .never }
        return splitwiseRuntimeChoice ?? .never
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
        if payeeName.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        if selectedAccountId == nil { return false }
        if splitwiseAuth.isAuthenticated, splitwiseRuntimeChoice == nil { return false }
        if resolvedSplitwiseAction != .never, selectedFriendId == nil && defaultFriend == nil { return false }
        if resolvedSplitwiseAction == .manual, Double(ownShareText) == nil { return false }
        return true
    }

    var body: some View {
        Group {
            if notAuthenticated {
                NotConnectedView(service: "YNAB", connect: ynabAuth.signIn)
            } else {
                content
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onAuthenticated(ynabAuth.isAuthenticated) {
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
                    title: "Payee",
                    isIncomplete: payeeName.trimmingCharacters(in: .whitespaces).isEmpty
                ) {
                    TextField("Payee Name", text: $payeeName)
                        .multilineTextAlignment(.trailing)
                        .submitLabel(.done)
                }
                .cardRowBackground()

                DraftDetailRow(
                    icon: "creditcard.fill",
                    title: "\(cardName)",
                    isIncomplete: selectedAccountId == nil
                ) {
                    if accountResolved {
                        Text(accounts.first { $0.id == selectedAccountId }?.name ?? "Unknown")
                    } else if isLoadingAccounts {
                        ProgressView()
                    } else {
                        MenuPickerField(
                            selection: $selectedAccountId,
                            label: accounts.first { $0.id == selectedAccountId }?.name ?? "Select account"
                        ) {
                            Text("None").tag(String?.none)
                            ForEach(accounts, id: \.id) { account in
                                Text(account.name).tag(Optional(account.id))
                            }
                        }
                    }
                }
                .cardRowBackground()

                DraftDetailRow(icon: "tag.fill", title: "Category") {
                    if isLoadingCategories {
                        ProgressView()
                    } else {
                        MenuPickerField(
                            selection: $selectedCategoryId,
                            label: categories.first { $0.id == selectedCategoryId }?.name ?? "Optional"
                        ) {
                            Text("None").tag(String?.none)
                            ForEach(categories, id: \.id) { category in
                                Text(category.name).tag(Optional(category.id))
                            }
                        }
                    }
                }
                .cardRowBackground()
            }

            if splitwiseAuth.isAuthenticated {
                Section("Split") {
                    SplitwiseSplitPickerRow(
                        choice: $splitwiseRuntimeChoice,
                        isIncomplete: splitwiseRuntimeChoice == nil
                    )

                    if resolvedSplitwiseAction != .never {
                        SplitwiseFriendPickerRow(
                            resolvedFriendName: templateHasFriend ? templateFriend?.fullName : nil,
                            isLoading: isLoadingFriends,
                            friends: friends,
                            selectedFriendId: $selectedFriendId,
                            noneLabel: defaultFriend.map { "Default (\($0.firstName))" } ?? "None",
                            isIncomplete: !templateHasFriend && selectedFriendId == nil && defaultFriend == nil
                        )
                    }

                    if resolvedSplitwiseAction == .manual {
                        SplitwiseOwnShareRow(ownShareText: $ownShareText, isIncomplete: Double(ownShareText) == nil)
                    }
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
                title: "Add Transaction",
                isLoading: isSubmitting,
                isDisabled: !canSubmit || isSubmitting
            ) {
                Task { await submit() }
            }
        }
    }

    private func load() async {
        guard case .ynabWallet = draft.payload else { return }

        // The form (with its locally-resolved defaults from init) is
        // already on screen at this point. This only needs to check auth
        // and kick off the category/account/friend refreshes — each
        // section owns its own spinner, so nothing here should block the
        // rest of the form from being usable.
        let token: String
        if isAuthenticatedOverride == true {
            token = "preview"
        } else if let real = await YNABAuthService.validAccessToken() {
            token = real
        } else {
            notAuthenticated = true
            return
        }

        async let categoriesTask: Void = loadCategoriesIfNeeded(token: token)
        async let accountsTask: Void = loadAccountsIfNeeded(token: token)
        async let friendsTask: Void = loadFriends()
        _ = await (categoriesTask, accountsTask, friendsTask)
    }

    private func loadCategoriesIfNeeded(token: String) async {
        // Still needed when templateResolved — the "Resolved From Template"
        // label maps selectedCategoryId to a name via this list, it just
        // skips showing the picker built from it.
        if let cached = YNABCategoryCacheStore.load() {
            categories = YNABCategoryUsageStore.sorted(cached)
        }
        isLoadingCategories = categories.isEmpty
        defer { isLoadingCategories = false }
        do {
            categories = YNABCategoryUsageStore.sorted(try await YNABCategoryCacheStore.fetch(token: token))
        } catch {
            logger.error("failed to load categories: \(String(describing: error), privacy: .public)")
        }
    }

    private func loadAccountsIfNeeded(token: String) async {
        // Still needed when accountResolved — the read-only account label
        // maps selectedAccountId to a name via this list, it just skips
        // showing the picker built from it.
        if let cached = YNABAccountCacheStore.load() {
            accounts = cached
        }
        isLoadingAccounts = accounts.isEmpty
        defer { isLoadingAccounts = false }
        do {
            accounts = try await YNABAccountCacheStore.fetch(token: token)
        } catch {
            logger.error("failed to load accounts: \(String(describing: error), privacy: .public)")
        }
    }

    private func loadFriends() async {
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
        guard case .ynabWallet(let merchant, let amount, let card) = draft.payload else { return }
        guard let token = await YNABAuthService.validAccessToken() else {
            notAuthenticated = true
            return
        }
        errorMessage = nil
        isSubmitting = true
        defer { isSubmitting = false }

        var config = WalletTransactionConfigStore.load()
        var configChanged = false

        let trimmedPayee = payeeName.trimmingCharacters(in: .whitespaces)
        guard !trimmedPayee.isEmpty else {
            errorMessage = "Payee name can't be empty."
            return
        }
        let finalPayeeName = trimmedPayee
        let finalCategoryId = selectedCategoryId

        if templateChoice == nil {
            // Creating a new template from payee name
            var template = config.templates[trimmedPayee] ?? WalletTransactionConfig.Template(categoryId: nil)
            template.categoryId = selectedCategoryId
            template.splitwiseOption = switch splitwiseRuntimeChoice {
            case .always: .always
            case .manual: .manual
            case .never, nil: .never
            }
            config.templates[trimmedPayee] = template
            config.merchants[merchant] = WalletTransactionConfig.MerchantInfo(payeeName: trimmedPayee, templateName: trimmedPayee)
            configChanged = true
        }

        guard let accountId = selectedAccountId else {
            errorMessage = "Pick an account."
            return
        }
        if !accountResolved {
            config.cards[card] = accountId
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

        // `let`, not `var` — assigned exactly once below (or the function
        // returns first) — since these are captured by the `async let`
        // below, a mutable var would be flagged as a data-race risk under
        // Swift 6 strict concurrency checking.
        let ownShare: Double?
        if action == .manual {
            switch SplitwiseExpenseHelper.parseOwnShare(ownShareText, amount: amount) {
            case .valid(let parsed): ownShare = parsed
            case .invalid(let message):
                errorMessage = message
                return
            }
        } else {
            ownShare = nil
        }

        let friend: SplitwiseFriendEntity?
        if action != .never {
            if let templateFriend {
                friend = templateFriend
            } else if let selectedFriendId, let match = friends.first(where: { $0.id == selectedFriendId }) {
                friend = SplitwiseFriendEntity(id: match.id, firstName: match.firstName, fullName: match.fullName)
            } else {
                errorMessage = "Pick a Splitwise friend."
                return
            }
        } else {
            friend = nil
        }

        let milliunits = -Int((amount * 1000).rounded())
        let transaction = YNABTransactionRequest(
            accountId: accountId,
            date: YNABService.todayDateString(),
            amount: milliunits,
            payeeName: finalPayeeName,
            categoryId: finalCategoryId,
            memo: nil,
            cleared: "uncleared",
            approved: true
        )
        let formattedAmount = amount.asMoneyString

        async let ynabOutcome = PendingSync.createYNABTransaction(transaction, token: token, summary: "\(formattedAmount) at \(finalPayeeName)")
        async let splitDialogFragment = createSplitIfNeeded(friend: friend, description: finalPayeeName, amount: amount, action: action, ownShare: ownShare)

        do {
            let outcome = try await ynabOutcome
            _ = WalletAutomationDialog.handleYNABOutcome(outcome, formattedAmount: formattedAmount, payeeName: finalPayeeName, categoryId: finalCategoryId)
            _ = await splitDialogFragment
            TransactionDraftGuard.complete(draft.id)
            dismiss()
        } catch {
            errorMessage = YNABIntentError.message(for: error)
        }
    }

    private func applyTemplate(_ name: String?) {
        let config = WalletTransactionConfigStore.load()
        guard let name else {
            withAnimation {
                selectedCategoryId = nil
                splitwiseRuntimeChoice = .never
                templateHasFriend = false
                templateFriend = nil
                selectedFriendId = SplitwiseDefaultFriendStore.load()?.id
            }
            return
        }
        let template = config.templates[name]
        let newFriend = template?.splitwiseFriend
        withAnimation {
            selectedCategoryId = template?.categoryId
            splitwiseRuntimeChoice = Self.runtimeChoice(for: template?.splitwiseOption ?? .never)
            if let newFriend {
                templateHasFriend = true
                templateFriend = SplitwiseFriendEntity(id: newFriend.id, firstName: newFriend.firstName, fullName: newFriend.fullName)
                selectedFriendId = newFriend.id
            } else {
                templateHasFriend = false
                templateFriend = nil
                selectedFriendId = SplitwiseDefaultFriendStore.load()?.id
            }
        }
    }

    private func createSplitIfNeeded(
        friend: SplitwiseFriendEntity?,
        description: String,
        amount: Double,
        action: SplitwiseSplitOption,
        ownShare: Double?
    ) async -> String? {
        guard action != .never, let friend else { return nil }
        return await WalletAutomationDialog.splitDialogFragment(amount: amount, description: description, friend: friend, ownShare: ownShare)
    }
}

#Preview {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            NavigationStack {
                ContinueYNABWalletTransactionView(
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
