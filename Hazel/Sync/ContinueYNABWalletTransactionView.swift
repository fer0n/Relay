//
//  ContinueYNABWalletTransactionView.swift
//  Hazel
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

private let logger = Logger(subsystem: "com.pentlandFirth.Hazel", category: "ContinueYNABWalletTransactionView")

struct ContinueYNABWalletTransactionView: View {
    let draft: TransactionDraft

    @State private var splitwiseAuth = SplitwiseAuthService()
    @State private var notAuthenticated = false
    @State private var errorMessage: String?
    @State private var resultMessage: String?
    @State private var isSubmitting = false

    /// True once a merchant→template match is found — payee/category/split
    /// setting are then fixed (read-only here) instead of asked again.
    @State private var templateResolved = false
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

    init(draft: TransactionDraft) {
        self.draft = draft

        // Resolved synchronously (local disk reads only) so the form's
        // payee/category/account defaults are in place on the very first
        // render — no need to wait on a `.task` for this part.
        guard case .ynabWallet(let merchant, _, let card) = draft.payload else { return }

        let config = WalletTransactionConfigStore.load()
        if let info = config.resolvedMerchantInfo(for: merchant) {
            _templateResolved = State(initialValue: true)
            _payeeName = State(initialValue: info.payeeName)
            let template = config.templates[info.templateName]
            _selectedCategoryId = State(initialValue: template?.categoryId)
            _resolvedTemplateSplitwiseOption = State(initialValue: template?.splitwiseOption ?? .never)
        } else {
            _payeeName = State(initialValue: merchant)
        }

        if let accountId = config.cards[card] {
            _accountResolved = State(initialValue: true)
            _selectedAccountId = State(initialValue: accountId)
        }

        if let defaultFriend = SplitwiseDefaultFriendStore.load() {
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
                ContentUnavailableView(
                    "Not Connected",
                    systemImage: "exclamationmark.triangle",
                    description: Text("Connect your YNAB account in Hazel first.")
                )
            } else if let resultMessage {
                ContentUnavailableView(
                    "Done",
                    systemImage: "banknote.fill",
                    description: Text(resultMessage)
                )
            } else {
                form
            }
        }
        .navigationTitle("Continue Transaction")
        .task { await load() }
    }

    private var form: some View {
        Form {
            Section {
                Text(draft.summary).font(.headline)
                Text("Started \(RelativeDateTimeFormatter().localizedString(for: draft.startedAt, relativeTo: Date()))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if templateResolved {
                Section("Resolved From Template") {
                    LabeledContent("Payee", value: payeeName)
                    LabeledContent("Category", value: categories.first { $0.id == selectedCategoryId }?.name ?? "None")
                }
            } else {
                Section("Payee") {
                    TextField("Payee Name", text: $payeeName)
                }
                Section("Category") {
                    if isLoadingCategories {
                        ProgressView()
                    } else {
                        Picker(selection: $selectedCategoryId) {
                            Text("None").tag(String?.none)
                            ForEach(categories, id: \.id) { category in
                                Text(category.name).tag(Optional(category.id))
                            }
                        } label: {
                            Text("Category").foregroundStyle(.tint)
                        }
                        .tint(.accentColor)
                    }
                }
            }

            Section("Account") {
                if accountResolved {
                    LabeledContent("Account", value: accounts.first { $0.id == selectedAccountId }?.name ?? "Unknown")
                } else if isLoadingAccounts {
                    ProgressView()
                } else {
                    Picker(selection: $selectedAccountId) {
                        Text("None").tag(String?.none)
                        ForEach(accounts, id: \.id) { account in
                            Text(account.name).tag(Optional(account.id))
                        }
                    } label: {
                        Text("Account").foregroundStyle(.tint)
                    }
                    .tint(.accentColor)
                }
            }

            if splitwiseAuth.isAuthenticated {
                Section("Splitwise") {
                    if templateResolved {
                        LabeledContent("Split Setting", value: resolvedTemplateSplitwiseOption.label)
                    } else {
                        Picker(selection: $newTemplateSplitwiseOption) {
                            ForEach([SplitwiseTemplateOption.ask, .always, .manual, .never], id: \.self) { option in
                                Text(option.label).tag(option)
                            }
                        } label: {
                            Text("Split With Splitwise").foregroundStyle(.tint)
                        }
                        .tint(.accentColor)
                    }

                    if effectiveSplitwiseOption == .ask {
                        Picker(selection: $splitwiseRuntimeChoice) {
                            Text("Choose").tag(SplitwiseSplitOption?.none)
                            ForEach([SplitwiseSplitOption.always, .manual, .never], id: \.self) { option in
                                Text(option.label).tag(SplitwiseSplitOption?.some(option))
                            }
                        } label: {
                            Text("Split This Transaction?").foregroundStyle(.tint)
                        }
                        .tint(.accentColor)
                    }

                    if resolvedSplitwiseAction != .never {
                        if isLoadingFriends {
                            ProgressView()
                        } else {
                            Picker(selection: $selectedFriendId) {
                                Text("None").tag(Int?.none)
                                splitwiseFriendRows(friends) { friend in
                                    Text(friend.fullName).tag(Optional(friend.id))
                                }
                            } label: {
                                Text("Split With").foregroundStyle(.tint)
                            }
                            .tint(.accentColor)
                        }
                    }

                    if resolvedSplitwiseAction == .manual {
                        TextField("Your Share", text: $ownShareText)
                            .keyboardType(.decimalPad)
                    }
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    Task { await submit() }
                } label: {
                    if isSubmitting {
                        ProgressView()
                    } else {
                        Text("Add Transaction")
                    }
                }
                .disabled(!canSubmit || isSubmitting)
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
        guard let token = await YNABAuthService.validAccessToken() else {
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
            guard let parsed = Double(ownShareText) else {
                errorMessage = "Enter a valid share amount."
                return
            }
            do {
                try SplitwiseExpenseHelper.validateOwnShare(parsed, amount: amount)
            } catch {
                errorMessage = (error as? SplitwiseIntentError).map { String(localized: $0.localizedStringResource) } ?? "Invalid share amount."
                return
            }
            ownShare = parsed
        } else {
            ownShare = nil
        }

        let friend: SplitwiseFriendEntity?
        if action != .never {
            guard let selectedFriendId, let match = friends.first(where: { $0.id == selectedFriendId }) else {
                errorMessage = "Pick a Splitwise friend."
                return
            }
            friend = SplitwiseFriendEntity(id: match.id, firstName: match.firstName, fullName: match.fullName)
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
        let formattedAmount = amount.formatted(.number.precision(.fractionLength(2)))

        async let ynabOutcome = PendingSync.createYNABTransaction(transaction, token: token, summary: "\(formattedAmount) at \(finalPayeeName)")
        async let splitDialogFragment = createSplitIfNeeded(friend: friend, description: finalPayeeName, amount: amount, action: action, ownShare: ownShare)

        do {
            let outcome = try await ynabOutcome
            var dialog = WalletAutomationDialog.handleYNABOutcome(outcome, formattedAmount: formattedAmount, payeeName: finalPayeeName, categoryId: finalCategoryId)
            if let fragment = await splitDialogFragment {
                dialog += fragment
            }
            TransactionDraftGuard.complete(draft.id)
            resultMessage = dialog
        } catch {
            errorMessage = (error as? YNABIntentError).map { String(localized: $0.localizedStringResource) } ?? "Couldn't add the transaction."
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
