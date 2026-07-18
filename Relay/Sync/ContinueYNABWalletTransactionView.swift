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

private let logger = Logger(subsystem: "com.pentlandFirth.Relay", category: "ContinueYNABWalletTransactionView")

struct ContinueYNABWalletTransactionView: View {
    let draft: TransactionDraft

    @State private var ynabAuth = YNABAuthService()
    @State private var splitwiseAuth = SplitwiseAuthService()
    @State private var notAuthenticated = false
    @State private var errorMessage: String?
    @State private var isSubmitting = false
    @Environment(\.dismiss) private var dismiss

    /// True once a merchant→template match is found — payee/category/split
    /// setting are then fixed (read-only here) instead of asked again.
    @State private var templateResolved = false
    @State private var resolvedTemplateName: String?
    @State private var payeeName = ""
    @State private var categories: [YNABCategory] = []
    @State private var selectedCategoryId: String?
    @State private var isLoadingCategories = false

    @State private var accountResolved = false
    @State private var accounts: [YNABAccount] = []
    @State private var selectedAccountId: String?
    @State private var isLoadingAccounts = false

    /// Only used/shown when `!templateResolved` — the split setting to save
    /// on the new template.
    @State private var newTemplateSplitwiseOption: SplitwiseTemplateOption = .never
    /// Only meaningful when `templateResolved` — the existing template's
    /// fixed split setting, shown read-only.
    @State private var resolvedTemplateSplitwiseOption: SplitwiseTemplateOption = .never

    @State private var splitwiseRuntimeChoice: SplitwiseSplitOption?
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

    /// Preview/testing seam only — nil (the default) always falls through
    /// to the real Keychain check. Lets `#Preview` render the form itself
    /// instead of racing the async "Not Connected" gate.
    let isAuthenticatedOverride: Bool?

    init(draft: TransactionDraft, isAuthenticatedOverride: Bool? = nil) {
        self.draft = draft
        self.isAuthenticatedOverride = isAuthenticatedOverride

        // Resolved synchronously (local disk reads only) so the form's
        // payee/category/account defaults are in place on the very first
        // render — no need to wait on a `.task` for this part.
        guard case .ynabWallet(let merchant, _, let card) = draft.payload else { return }

        let config = WalletTransactionConfigStore.load()
        var resolvedTemplateFriend: (id: Int, firstName: String, fullName: String)?
        if let info = config.resolvedMerchantInfo(for: merchant) {
            _templateResolved = State(initialValue: true)
            _resolvedTemplateName = State(initialValue: info.templateName)
            _payeeName = State(initialValue: info.payeeName)
            let template = config.templates[info.templateName]
            _selectedCategoryId = State(initialValue: template?.categoryId)
            _resolvedTemplateSplitwiseOption = State(initialValue: template?.splitwiseOption ?? .never)
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

    // A template can carry a non-.never split setting from before Splitwise
    // was disconnected — treat as "never split" for this run rather than
    // showing a Splitwise picker/friend field with nothing behind it.
    private var effectiveSplitwiseOption: SplitwiseTemplateOption {
        guard splitwiseAuth.isAuthenticated else { return .never }
        return templateResolved ? resolvedTemplateSplitwiseOption : newTemplateSplitwiseOption
    }

    private var resolvedSplitwiseAction: SplitwiseSplitOption {
        WalletAutomationDialog.resolvedSplitwiseAction(for: effectiveSplitwiseOption, runtimeChoice: splitwiseRuntimeChoice)
    }

    private var canSubmit: Bool {
        if !templateResolved, payeeName.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        if selectedAccountId == nil { return false }
        if effectiveSplitwiseOption == .ask, splitwiseRuntimeChoice == nil { return false }
        if resolvedSplitwiseAction != .never, selectedFriendId == nil { return false }
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
        .navigationTitle("Transaction draft")
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
            .listRowBackground(Color.backgroundColor)

            Section {
                DraftDetailRow(
                    icon: "text.alignleft",
                    title: "Payee",
                    isIncomplete: !templateResolved && payeeName.trimmingCharacters(in: .whitespaces).isEmpty
                ) {
                    if templateResolved {
                        Text(payeeName)
                    } else {
                        TextField("Payee Name", text: $payeeName)
                            .multilineTextAlignment(.trailing)
                    }
                }
                .cardRowBackground()

                DraftDetailRow(icon: "tag.fill", title: "Category") {
                    if templateResolved {
                        Text(categories.first { $0.id == selectedCategoryId }?.name ?? "None")
                    } else if isLoadingCategories {
                        ProgressView()
                    } else {
                        MenuPickerField(
                            selection: $selectedCategoryId,
                            label: categories.first { $0.id == selectedCategoryId }?.name ?? "None"
                        ) {
                            Text("None").tag(String?.none)
                            ForEach(categories, id: \.id) { category in
                                Text(category.name).tag(Optional(category.id))
                            }
                        }
                    }
                }
                .cardRowBackground()

                DraftDetailRow(icon: "creditcard.fill", title: "Account", isIncomplete: selectedAccountId == nil) {
                    if accountResolved {
                        Text(accounts.first { $0.id == selectedAccountId }?.name ?? "Unknown")
                    } else if isLoadingAccounts {
                        ProgressView()
                    } else {
                        MenuPickerField(
                            selection: $selectedAccountId,
                            label: accounts.first { $0.id == selectedAccountId }?.name ?? "None"
                        ) {
                            Text("None").tag(String?.none)
                            ForEach(accounts, id: \.id) { account in
                                Text(account.name).tag(Optional(account.id))
                            }
                        }
                    }
                }
                .cardRowBackground()

                DraftDetailRow(icon: "doc.on.doc", title: "Template") {
                    Text(templateResolved ? (resolvedTemplateName ?? "Unknown") : "New")
                }
                .cardRowBackground()

                DraftDetailRow(icon: draft.service.systemImage, title: "Provider") {
                    Text(draft.service.displayName)
                }
                .cardRowBackground()
            }

            if splitwiseAuth.isAuthenticated {
                Section("Split") {
                    SplitwiseOptionRow(
                        title: "Split With Splitwise",
                        isResolved: templateResolved,
                        resolvedOption: resolvedTemplateSplitwiseOption,
                        newOption: $newTemplateSplitwiseOption
                    )

                    if effectiveSplitwiseOption == .ask {
                        SplitwiseAskRow(runtimeChoice: $splitwiseRuntimeChoice, isIncomplete: splitwiseRuntimeChoice == nil)
                    }

                    if resolvedSplitwiseAction != .never {
                        SplitwiseFriendPickerRow(
                            resolvedFriendName: templateHasFriend ? templateFriend?.fullName : nil,
                            isLoading: isLoadingFriends,
                            friends: friends,
                            selectedFriendId: $selectedFriendId,
                            isIncomplete: !templateHasFriend && selectedFriendId == nil
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
                .listRowBackground(Color.backgroundColor)
            }
        }
        .themedList(background: .backgroundColor)
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
        let finalPayeeName: String
        let finalCategoryId: String?

        if templateResolved {
            finalPayeeName = payeeName
            finalCategoryId = selectedCategoryId
        } else {
            let trimmed = payeeName.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                errorMessage = "Payee name can't be empty."
                return
            }
            var template = config.templates[trimmed] ?? WalletTransactionConfig.Template(categoryId: nil)
            template.categoryId = selectedCategoryId
            template.splitwiseOption = newTemplateSplitwiseOption
            config.templates[trimmed] = template
            config.merchants[merchant] = WalletTransactionConfig.MerchantInfo(payeeName: trimmed, templateName: trimmed)
            finalPayeeName = trimmed
            finalCategoryId = selectedCategoryId
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
