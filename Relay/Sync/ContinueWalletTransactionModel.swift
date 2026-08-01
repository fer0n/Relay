//
//  ContinueWalletTransactionModel.swift
//  Relay
//
//  Form state + load/submit logic behind ContinueWalletTransactionView.
//

import SwiftUI
import os

private let logger = Logger(subsystem: Const.loggerSubsystem, category: "ContinueWalletTransactionModel")

@MainActor
@Observable
final class ContinueWalletTransactionModel {
    enum Mode: String { case ynab, splitwise }

    // MARK: Inputs

    let draft: TransactionDraft

    /// From-scratch entry rather than finishing a shortcut-started draft, so
    /// nothing is written back to the merchant/card/template config.
    let isManual: Bool

    let isPrefilled: Bool
    let isAuthenticatedOverride: Bool?

    private let defaultFriend: SplitwiseDefaultFriend?
    /// Wins over both a template's cached friend and the app-wide default —
    /// e.g. "Add Transaction" from a specific friend's page. See the
    /// equivalent precedence in AddWalletTransactionToSplitwiseIntent.resolveFriend.
    private let friendOverride: SplitwiseFriendEntity?

    // MARK: Services / status

    let ynabAuth = YNABAuthService()
    let splitwiseAuth = SplitwiseAuthService()
    var notAuthenticated = false
    var errorMessage: String?
    var isSubmitting = false

    // MARK: Fields

    var payeeText = ""
    var descriptionText = ""
    var isDescriptionManuallyEdited = false
    var memoText = ""
    var amountText = ""
    var manualMode: Mode = .ynab
    var templateChoice: String?
    var availableTemplates: [String] = []
    private var cachedTemplatePayeeNames: [String: [String]] = [:]

    var categories: [YNABCategory] = []
    var selectedCategoryId: String?
    var isLoadingCategories = false

    var accountResolved = false
    var accounts: [YNABAccount] = []
    var selectedAccountId: String?
    var isLoadingAccounts = false

    var splitwiseRuntimeChoice: SplitwiseSplitOption? = .never
    var friends: [SplitwiseFriend] = []
    var selectedFriendId: Int?
    var isLoadingFriends = false
    var ownShareText = ""

    /// A template's own friend beats the app-wide default and is shown
    /// read-only rather than re-offered as a choice.
    var templateHasFriend = false
    var templateFriend: SplitwiseFriendEntity?

    // MARK: Init

    init(draft: TransactionDraft, isManual: Bool = false, prefill: TransactionHistoryEntry? = nil, isAuthenticatedOverride: Bool? = nil, friendOverride: SplitwiseFriendEntity? = nil) {
        self.draft = draft
        self.isManual = isManual
        self.isPrefilled = prefill != nil
        self.isAuthenticatedOverride = isAuthenticatedOverride
        self.friendOverride = friendOverride
        defaultFriend = SplitwiseDefaultFriendStore.load()

        if isManual {
            let startMode = friendOverride != nil
                ? Mode.splitwise
                : prefill.map { $0.service == .splitwise ? Mode.splitwise : Mode.ynab }
                    ?? Self.resolveManualMode(ynabAuthenticated: ynabAuth.isAuthenticated, splitwiseAuthenticated: splitwiseAuth.isAuthenticated)
            manualMode = startMode
            let config = WalletTransactionConfigStore.load()
            availableTemplates = Array(config.templates.keys)
            cachedTemplatePayeeNames = Self.payeeNamesByTemplate(config)
            if let friendOverride {
                selectedFriendId = friendOverride.id
            } else if let defaultFriend {
                selectedFriendId = defaultFriend.id
            }
            if let prefill {
                applyPrefill(prefill, config: config)
            } else {
                selectedAccountId = Self.loadLastManualAccountId()
                splitwiseRuntimeChoice = Self.loadLastSplitChoice() ?? (startMode == .splitwise ? .always : .never)
                if let lastTemplate = Self.loadLastManualTemplate(), availableTemplates.contains(lastTemplate) {
                    templateChoice = lastTemplate
                    applyTemplate(lastTemplate)
                }
            }
            return
        }

        // Local disk reads only, so defaults are in place on the first render.
        switch draft.payload {
        case .ynabWallet(let merchant, _, let card):
            let config = WalletTransactionConfigStore.load()
            availableTemplates = Array(config.templates.keys)
            cachedTemplatePayeeNames = Self.payeeNamesByTemplate(config)

            var resolvedTemplateFriend: (id: Int, firstName: String, fullName: String)?
            if let info = config.resolvedMerchantInfo(for: merchant) {
                templateChoice = info.templateName
                payeeText = info.payeeName
                let template = config.templates[info.templateName]
                selectedCategoryId = template?.categoryId
                // Never the global last-used choice, which would let the last
                // manual entry's pick spill into this draft.
                splitwiseRuntimeChoice = (template?.splitwiseOption ?? .never).splitRuntimeChoice
                resolvedTemplateFriend = template?.splitwiseFriend
            } else {
                payeeText = merchant
                // No template to carry a split default, so canSubmit's nil
                // check forces an explicit pick.
                splitwiseRuntimeChoice = nil
            }

            if let accountId = config.cards[card] {
                accountResolved = true
                selectedAccountId = accountId
            }

            if let resolvedTemplateFriend {
                templateHasFriend = true
                templateFriend = SplitwiseFriendEntity(templateFriend: resolvedTemplateFriend)
                selectedFriendId = resolvedTemplateFriend.id
            } else if let defaultFriend {
                selectedFriendId = defaultFriend.id
            }

        case .splitwiseWallet(let merchant, _, _):
            if let ownShare = draft.ownShare {
                ownShareText = String(ownShare)
            }
            splitwiseRuntimeChoice = .always

            // A plain Keychain read (no network), unlike YNAB's token check, so
            // the auth gate settles here instead of behind a `.task`.
            let isAuthenticated = isAuthenticatedOverride ?? (SplitwiseAuthService.currentAccessToken != nil)
            guard isAuthenticated else {
                notAuthenticated = true
                return
            }

            let config = WalletTransactionConfigStore.load()
            availableTemplates = Array(config.templates.keys)
            cachedTemplatePayeeNames = Self.payeeNamesByTemplate(config)

            if let info = config.resolvedMerchantInfo(for: merchant) {
                templateChoice = info.templateName
                payeeText = info.payeeName
                let template = config.templates[info.templateName]
                // Never the global last-used choice, which would let the last
                // manual entry's pick spill into this draft.
                splitwiseRuntimeChoice = (template?.splitwiseOption ?? .never).splitRuntimeChoice
                if let friend = template?.splitwiseFriend {
                    templateHasFriend = true
                    templateFriend = SplitwiseFriendEntity(templateFriend: friend)
                    selectedFriendId = friend.id
                }
            } else {
                // No template to carry a split default, so canSubmit's nil
                // check forces an explicit pick.
                splitwiseRuntimeChoice = nil
            }
        }
    }

    private func applyPrefill(_ entry: TransactionHistoryEntry, config: WalletTransactionConfig) {
        switch entry.payload {
        case .ynabTransaction(let transaction):
            amountText = (abs(Double(transaction.amount)) / Const.milliunitsPerUnit).asMoneyString
            payeeText = transaction.payeeName
            selectedAccountId = transaction.accountId
            selectedCategoryId = transaction.categoryId
            memoText = transaction.memo ?? ""
        case .splitwiseExpense(let expense):
            amountText = (Double(expense.costCents) / Const.centsPerUnit).asMoneyString
            payeeText = expense.description
        }

        // Assigned directly rather than via applyTemplate(): the fields a
        // template would push are already seeded from the entry, which is what
        // a re-add should reproduce.
        templateChoice = config.templateName(forPayeeName: payeeText, merchant: entry.merchant)

        let splitExpense: SplitwiseExpenseRequest?
        if let split = entry.split {
            splitExpense = split.expense
        } else if case .splitwiseExpense(let expense) = entry.payload {
            splitExpense = expense
        } else {
            splitExpense = nil
        }
        guard let splitExpense else {
            splitwiseRuntimeChoice = .never
            return
        }
        templateHasFriend = false
        templateFriend = nil
        selectedFriendId = splitExpense.friendUserId
        if splitExpense.payerOwedCents == splitExpense.costCents / 2 {
            splitwiseRuntimeChoice = .always
        } else {
            splitwiseRuntimeChoice = .manual
            ownShareText = String(Double(splitExpense.payerOwedCents) / Const.centsPerUnit)
        }
    }

    // MARK: Derived state

    var mode: Mode {
        if isManual { return manualMode }
        if case .ynabWallet = draft.payload { return .ynab }
        return .splitwise
    }

    var isModeAuthenticated: Bool {
        switch mode {
        case .ynab: ynabAuth.isAuthenticated
        case .splitwise: splitwiseAuth.isAuthenticated
        }
    }

    var cardName: String {
        if case .ynabWallet(_, _, let card) = draft.payload, !card.isEmpty { return card }
        return "Account"
    }

    var resolvedSplitwiseAction: SplitwiseSplitOption {
        // A template can carry a non-.never setting from before Splitwise was
        // disconnected; don't show a picker with nothing behind it.
        if mode == .ynab, !splitwiseAuth.isAuthenticated { return .never }
        return splitwiseRuntimeChoice ?? .never
    }

    var manualAmount: Double? {
        guard let parsed = try? AmountParser.parse(amountText), parsed > 0 else { return nil }
        return parsed
    }

    /// Whether the amount is a typed-in field rather than the fixed header.
    var amountIsEditable: Bool {
        isManual || draft.receivedNoValues
    }

    var canSubmit: Bool {
        if amountIsEditable, manualAmount == nil { return false }
        switch mode {
        case .ynab:
            if payeeText.trimmingCharacters(in: .whitespaces).isEmpty { return false }
            if selectedAccountId == nil { return false }
            // No auto-create/uncategorized path here, unlike Splitwise's.
            if templateChoice == nil { return false }
            if selectedCategoryId == nil { return false }
            if splitwiseAuth.isAuthenticated, splitwiseRuntimeChoice == nil { return false }
            if resolvedSplitwiseAction != .never, selectedFriendId == nil && defaultFriend == nil { return false }
            if resolvedSplitwiseAction == .manual, Double(ownShareText) == nil { return false }
        case .splitwise:
            if splitwiseDescription.isEmpty { return false }
            if selectedFriendId == nil && defaultFriend == nil { return false }
            if splitwiseRuntimeChoice == nil { return false }
            if resolvedSplitwiseAction == .manual, Double(ownShareText) == nil { return false }
        }
        return true
    }

    var friendNoneLabel: String {
        defaultFriend.map { "Default (\($0.firstName))" } ?? "None"
    }

    var friendRowIsIncomplete: Bool {
        !templateHasFriend && selectedFriendId == nil && defaultFriend == nil
    }

    var resolvedFriendName: String? {
        templateHasFriend ? templateFriend?.fullName : nil
    }

    var ynabPayeeName: String {
        payeeText.trimmingCharacters(in: .whitespaces)
    }

    var ynabMemo: String? {
        let trimmed = memoText.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Description for the Splitwise half of a `.ynab`-mode transaction.
    var splitDescription: String {
        guard let ynabMemo else { return ynabPayeeName }
        return "\(ynabPayeeName): \(ynabMemo)"
    }

    var splitwisePayeeName: String {
        let typed = payeeText.trimmingCharacters(in: .whitespaces)
        return typed.isEmpty ? draft.merchant : typed
    }

    /// Doubles as the Description field's placeholder.
    var splitwiseDescription: String {
        let typed = descriptionText.trimmingCharacters(in: .whitespaces)
        return typed.isEmpty ? splitwisePayeeName : typed
    }

    // MARK: Manual mode

    func setManualMode(_ newMode: Mode) {
        guard newMode != manualMode else { return }
        withAnimation { manualMode = newMode }
        Self.saveLastManualMode(newMode)
        splitwiseRuntimeChoice = newMode == .splitwise ? .always : .never
    }

    private static let lastManualModeKey = "lastManualTransactionMode"
    private static func loadLastManualMode() -> Mode? {
        UserDefaults.standard.string(forKey: lastManualModeKey).flatMap(Mode.init(rawValue:))
    }

    /// With one service connected that one wins over the last-used mode, so a
    /// Splitwise-only user never lands on a "Connect YNAB" dead end.
    private static func resolveManualMode(ynabAuthenticated: Bool, splitwiseAuthenticated: Bool) -> Mode {
        if ynabAuthenticated && splitwiseAuthenticated {
            return loadLastManualMode() ?? .ynab
        }
        return splitwiseAuthenticated ? .splitwise : .ynab
    }
    private static func saveLastManualMode(_ mode: Mode) {
        UserDefaults.standard.set(mode.rawValue, forKey: lastManualModeKey)
    }

    // MARK: Manual account / split persistence

    /// Bound in the view instead of the plain property so the choice persists.
    func setSelectedAccountId(_ id: String?) {
        selectedAccountId = id
        guard isManual else { return }
        Self.saveLastManualAccountId(id)
    }

    /// Bound in the view instead of the plain property so the choice persists.
    func setSplitwiseRuntimeChoice(_ choice: SplitwiseSplitOption?) {
        splitwiseRuntimeChoice = choice
        if isManual {
            Self.saveLastSplitChoice(choice)
        }
    }

    private static let lastManualAccountIdKey = "lastManualTransactionAccountId"
    private static func loadLastManualAccountId() -> String? {
        UserDefaults.standard.string(forKey: lastManualAccountIdKey)
    }
    private static func saveLastManualAccountId(_ id: String?) {
        UserDefaults.standard.set(id, forKey: lastManualAccountIdKey)
    }

    private static let lastSplitChoiceKey = "lastManualTransactionSplitChoice"
    private static func loadLastSplitChoice() -> SplitwiseSplitOption? {
        UserDefaults.standard.string(forKey: lastSplitChoiceKey).flatMap(SplitwiseSplitOption.init(rawValue:))
    }
    private static func saveLastSplitChoice(_ choice: SplitwiseSplitOption?) {
        UserDefaults.standard.set(choice?.rawValue, forKey: lastSplitChoiceKey)
    }

    private static let lastManualTemplateKey = "lastManualTransactionTemplate"
    private static func loadLastManualTemplate() -> String? {
        UserDefaults.standard.string(forKey: lastManualTemplateKey)
    }
    private static func saveLastManualTemplate(_ name: String?) {
        UserDefaults.standard.set(name, forKey: lastManualTemplateKey)
    }

    // MARK: Template application

    /// Re-applies the fields a template controls, or resets to per-mode
    /// defaults when the selection is cleared.
    func applyTemplate(_ name: String?) {
        if isManual {
            Self.saveLastManualTemplate(name)
        }
        let config = WalletTransactionConfigStore.load()
        let template = name.flatMap { config.templates[$0] }
        withAnimation {
            if mode == .ynab {
                selectedCategoryId = template?.categoryId
            }
            if isManual {
                // The global last-used choice wins over the template's own.
                if name == nil {
                    splitwiseRuntimeChoice = Self.loadLastSplitChoice() ?? (mode == .splitwise ? .always : .never)
                } else {
                    splitwiseRuntimeChoice = Self.loadLastSplitChoice() ?? (template?.splitwiseOption ?? .never).splitRuntimeChoice
                }
            } else {
                // Drafts never read the global last-used choice: follow the
                // picked template's option, or stay unset to force a pick.
                splitwiseRuntimeChoice = name == nil ? nil : (template?.splitwiseOption ?? .never).splitRuntimeChoice
            }
            if let friendOverride {
                templateHasFriend = false
                templateFriend = nil
                selectedFriendId = friendOverride.id
            } else if let friend = template?.splitwiseFriend {
                templateHasFriend = true
                templateFriend = SplitwiseFriendEntity(templateFriend: friend)
                selectedFriendId = friend.id
            } else {
                templateHasFriend = false
                templateFriend = nil
                selectedFriendId = SplitwiseDefaultFriendStore.load()?.id
            }
        }
    }

    func templateSaved(_ name: String) {
        let config = WalletTransactionConfigStore.load()
        availableTemplates = Array(config.templates.keys)
        cachedTemplatePayeeNames = Self.payeeNamesByTemplate(config)
        templateChoice = name
        applyTemplate(name)
    }

    private static func payeeNamesByTemplate(_ config: WalletTransactionConfig) -> [String: [String]] {
        config.templates.mapValues { Array(Set($0.autoMatch.map(\.payeeName))).sorted() }
    }

    /// Autocomplete for the payee field's keyboard toolbar, selected template
    /// first so its names win the limited slots.
    var suggestedPayeeNames: [String] {
        let ownNames = templateChoice.flatMap { cachedTemplatePayeeNames[$0] } ?? []
        let otherNames = Array(Set(cachedTemplatePayeeNames.values.flatMap { $0 }).subtracting(ownNames)).sorted()
        let names = ownNames + otherNames
        let typed = payeeText.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return names }
        return names.filter { $0.localizedStandardContains(typed) }
    }

    /// Whether to offer the "Add to <template>" action: few enough matches that
    /// this looks like a new payee, and no rule for this exact text yet.
    var showsLinkToTemplate: Bool {
        let typed = payeeText.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return false }
        let names = suggestedPayeeNames
        guard !names.contains(where: { $0.caseInsensitiveCompare(typed) == .orderedSame }) else { return false }
        return names.count <= 2
    }

    var linkToTemplateName: String {
        templateChoice ?? payeeText.trimmingCharacters(in: .whitespaces)
    }

    /// Adds an auto-match rule for the typed payee to the selected template, or
    /// a new one named after it. Unlike submit()'s equivalent path, this also
    /// works for manual entries, which have no merchant to map.
    func linkPayeeToTemplate() {
        let trimmed = payeeText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let templateName = linkToTemplateName
        var config = WalletTransactionConfigStore.load()
        var template = config.templates[templateName] ?? WalletTransactionConfig.Template()
        let rule = WalletTransactionConfig.AutoMatchRule(pattern: trimmed, payeeName: trimmed)
        guard !template.autoMatch.contains(rule) else { return }
        template.autoMatch.append(rule)
        config.templates[templateName] = template
        do {
            try WalletTransactionConfigStore.save(config)
        } catch {
            logger.error("failed to link payee to template: \(String(describing: error), privacy: .public)")
            return
        }
        if templateChoice == nil {
            availableTemplates = Array(config.templates.keys)
            templateChoice = templateName
        }
        cachedTemplatePayeeNames = Self.payeeNamesByTemplate(config)
    }

    // MARK: Loading

    func load() async {
        if isManual {
            await loadManual()
            return
        }
        switch mode {
        case .ynab:
            await loadYNAB()
        case .splitwise:
            guard !notAuthenticated else { return }
            await loadFriends()
        }
    }

    /// A manual entry can switch modes at any time, so load both services.
    private func loadManual() async {
        async let ynabTask: Void = loadManualYNAB()
        async let friendsTask: Void = loadFriends()
        _ = await (ynabTask, friendsTask)
    }

    private func loadManualYNAB() async {
        guard ynabAuth.isAuthenticated else { return }
        let token: String
        if isAuthenticatedOverride == true {
            token = "preview"
        } else if let real = await YNABAuthService.validAccessToken() {
            token = real
        } else {
            return
        }
        async let categoriesTask: Void = loadCategoriesIfNeeded(token: token)
        async let accountsTask: Void = loadAccountsIfNeeded(token: token)
        _ = await (categoriesTask, accountsTask)
    }

    private func loadYNAB() async {
        guard case .ynabWallet = draft.payload else { return }

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
        if let cached = YNABCategoryCacheStore.load() {
            categories = YNABCategoryUsageStore.sorted(cached)
        }
        // Skip the live fetch while the cache is fresh — YNAB allows 200 req/hr.
        guard YNABCategoryCacheStore.isStale else { return }
        isLoadingCategories = categories.isEmpty
        defer { isLoadingCategories = false }
        do {
            categories = YNABCategoryUsageStore.sorted(try await YNABCategoryCacheStore.fetch(token: token))
        } catch {
            logger.error("failed to load categories: \(String(describing: error), privacy: .public)")
        }
    }

    private func loadAccountsIfNeeded(token: String) async {
        if let cached = YNABAccountCacheStore.load() {
            accounts = cached
        }
        guard YNABAccountCacheStore.isStale else { return }
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
        guard SplitwiseFriendCacheStore.isStale else { return }
        isLoadingFriends = friends.isEmpty
        defer { isLoadingFriends = false }
        do {
            friends = SplitwiseFriendUsageStore.sorted(try await SplitwiseFriendCacheStore.fetch(token: token))
        } catch {
            logger.error("failed to load friends: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Submit

    /// `true` means the view should dismiss; `false` leaves the form up with an
    /// inline error or auth gate.
    func submit() async -> Bool {
        switch mode {
        case .ynab: await submitYNAB()
        case .splitwise: await submitSplitwise()
        }
    }

    private func submitYNAB() async -> Bool {
        let merchant: String
        let card: String
        let amount: Double
        if isManual {
            merchant = ""
            card = ""
            amount = manualAmount ?? 0
        } else {
            guard case .ynabWallet(let m, let a, let c) = draft.payload else { return false }
            merchant = m
            card = c
            amount = draft.receivedNoValues ? (manualAmount ?? 0) : a
        }
        guard let token = await YNABAuthService.validAccessToken() else {
            notAuthenticated = true
            return false
        }
        errorMessage = nil
        isSubmitting = true
        defer { isSubmitting = false }

        var config = WalletTransactionConfigStore.load()
        var configChanged = false

        let trimmedPayee = ynabPayeeName
        guard !trimmedPayee.isEmpty else {
            errorMessage = "Payee name can't be empty."
            return false
        }
        let finalPayeeName = trimmedPayee
        let finalCategoryId = selectedCategoryId

        if !isManual, let templateChoice, config.linkMerchantIfChanged(merchant: merchant, payeeName: finalPayeeName, templateName: templateChoice) {
            configChanged = true
        }

        guard let accountId = selectedAccountId else {
            errorMessage = "Pick an account."
            return false
        }
        if !isManual, !accountResolved {
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

        // `let`, not `var`: captured by the `async let` below, where a mutable
        // var trips Swift 6 strict concurrency checking.
        let ownShare: Double?
        if action == .manual {
            switch SplitwiseExpenseHelper.parseOwnShare(ownShareText, amount: amount) {
            case .valid(let parsed): ownShare = parsed
            case .invalid(let message):
                errorMessage = message
                return false
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
                return false
            }
        } else {
            friend = nil
        }

        let milliunits = -Int((amount * Const.milliunitsPerUnit).rounded())
        let transaction = YNABTransactionRequest(
            accountId: accountId,
            date: YNABService.todayDateString(),
            amount: milliunits,
            payeeName: finalPayeeName,
            categoryId: finalCategoryId,
            memo: ynabMemo,
            cleared: Const.YNAB.uncleared,
            approved: true
        )
        let formattedAmount = amount.asMoneyString

        // Folds the YNAB write and the split into one history entry.
        let groupId = (action != .never && friend != nil) ? UUID() : nil

        async let ynabOutcome = PendingSync.createYNABTransaction(transaction, token: token, summary: "\(formattedAmount) at \(finalPayeeName)", groupId: groupId, merchant: isManual ? nil : merchant)
        async let splitDialogFragment = createSplitIfNeeded(friend: friend, description: splitDescription, amount: amount, action: action, ownShare: ownShare, groupId: groupId, merchant: isManual ? nil : merchant)

        do {
            let outcome = try await ynabOutcome
            _ = WalletAutomationDialog.handleYNABOutcome(outcome, formattedAmount: formattedAmount, payeeName: finalPayeeName, categoryId: finalCategoryId)
            _ = await splitDialogFragment
            TransactionDraftGuard.complete(draft.id)
            return true
        } catch {
            errorMessage = YNABIntentError.message(for: error)
            return false
        }
    }

    private func createSplitIfNeeded(
        friend: SplitwiseFriendEntity?,
        description: String,
        amount: Double,
        action: SplitwiseSplitOption,
        ownShare: Double?,
        groupId: UUID?,
        merchant: String?
    ) async -> String? {
        guard action != .never, let friend else { return nil }
        return await WalletAutomationDialog.splitDialogFragment(amount: amount, description: description, friend: friend, ownShare: ownShare, groupId: groupId, merchant: merchant).fragment
    }

    private func submitSplitwise() async -> Bool {
        let merchant: String
        let amount: Double
        if isManual {
            merchant = ""
            amount = manualAmount ?? 0
        } else {
            guard case .splitwiseWallet(let m, let a, _) = draft.payload else { return false }
            merchant = m
            amount = draft.receivedNoValues ? (manualAmount ?? 0) : a
        }
        guard SplitwiseAuthService.currentAccessToken != nil else {
            notAuthenticated = true
            return false
        }
        errorMessage = nil
        isSubmitting = true
        defer { isSubmitting = false }

        var config = WalletTransactionConfigStore.load()
        var configChanged = false

        let finalDescription = splitwiseDescription
        guard !finalDescription.isEmpty else {
            errorMessage = "Description can't be empty."
            return false
        }
        let finalPayeeName = splitwisePayeeName
        let finalTemplateName: String
        if let templateChoice {
            finalTemplateName = templateChoice
        } else if !isManual {
            // An untemplated draft goes under the default template rather than
            // spawning a per-payee one, matching the intent's flow.
            finalTemplateName = config.ensureSplitwiseDefaultTemplate()
        } else {
            finalTemplateName = finalPayeeName
        }

        let finalFriend: WalletTransactionConfig.CachedFriend
        if templateHasFriend, let existing = config.templates[finalTemplateName]?.splitwiseFriend {
            finalFriend = existing
        } else {
            guard let selectedFriendId, let match = friends.first(where: { $0.id == selectedFriendId }) else {
                errorMessage = "Pick a Splitwise friend."
                return false
            }
            finalFriend = (match.id, match.firstName, match.fullName)
        }

        if !isManual {
            // The template's split option is left as-is — the runtime choice
            // here is one-shot, not a setting.
            configChanged = config.recordSplitwiseMerchantLink(
                merchant: merchant,
                payeeName: finalPayeeName,
                templateName: finalTemplateName,
                friend: finalFriend
            )
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
            return true
        }

        var ownShare: Double?
        if action == .manual {
            switch SplitwiseExpenseHelper.parseOwnShare(ownShareText, amount: amount) {
            case .valid(let parsed): ownShare = parsed
            case .invalid(let message):
                errorMessage = message
                return false
            }
        }

        do {
            _ = try await SplitwiseExpenseHelper.addExpense(
                amount: amount,
                description: finalDescription,
                friend: SplitwiseFriendEntity(templateFriend: finalFriend),
                ownShare: ownShare,
                merchant: isManual ? nil : merchant
            )
            TransactionDraftGuard.complete(draft.id)
            return true
        } catch {
            errorMessage = SplitwiseIntentError.message(for: error)
            return false
        }
    }
}
