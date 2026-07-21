//
//  ContinueWalletTransactionModel.swift
//  Relay
//
//  Form state + load/submit logic behind ContinueWalletTransactionView.
//  Holds every editable field, the auth services, and the async work
//  (resolving defaults from WalletTransactionConfigStore, loading YNAB
//  categories/accounts and Splitwise friends, and writing the transaction/
//  expense via PendingSync/SplitwiseExpenseHelper) so the view itself is
//  just the SwiftUI layout that binds to these properties.
//
//  Mirrors AddWalletTransactionToYNABIntent.perform() and
//  AddWalletTransactionToSplitwiseIntent.perform() — the only difference is
//  that the remaining questions are asked through this form's bindings
//  instead of requestValue/requestDisambiguation.
//

import SwiftUI
import os

private let logger = Logger(subsystem: "com.octabits.relay", category: "ContinueWalletTransactionModel")

@MainActor
@Observable
final class ContinueWalletTransactionModel {
    enum Mode: String { case ynab, splitwise }

    // MARK: Inputs

    let draft: TransactionDraft

    /// True when this is a from-scratch manual entry (the "+" button) rather
    /// than finishing a shortcut-started draft: the amount becomes an
    /// editable field instead of a fixed header, and none of the
    /// merchant/card/template auto-mapping (which only makes sense for a
    /// recognized shortcut merchant) is written back to config.
    let isManual: Bool

    /// Preview/testing seam only — nil (the default) always falls through to
    /// the real Keychain check. Lets `#Preview` render the form itself
    /// instead of racing the async "Not Connected" gate.
    let isAuthenticatedOverride: Bool?

    private let defaultFriend: SplitwiseDefaultFriend?

    // MARK: Services / status

    let ynabAuth = YNABAuthService()
    let splitwiseAuth = SplitwiseAuthService()
    var notAuthenticated = false
    var errorMessage: String?
    var isSubmitting = false

    // MARK: Fields

    /// Payee (YNAB draft) or expense description (Splitwise draft).
    var payeeText = ""
    /// Raw amount text — only used for a manual entry (isManual); a
    /// shortcut-started draft's amount comes fixed from the payload.
    var amountText = ""
    /// Selected mode for a manual entry (isManual) — switchable via the
    /// nav-bar menu; ignored otherwise (mode comes from the payload).
    var manualMode: Mode = .ynab
    var templateChoice: String?
    var availableTemplates: [String] = []

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

    /// True once the resolved template already has its own cached Splitwise
    /// friend — that takes precedence over the app-wide default
    /// (SplitwiseDefaultFriendStore) and is shown read-only rather than
    /// re-offered as a choice. Kept as a full entity (not just an id) so
    /// submit() can use it directly.
    var templateHasFriend = false
    var templateFriend: SplitwiseFriendEntity?

    // MARK: Init

    init(draft: TransactionDraft, isManual: Bool = false, isAuthenticatedOverride: Bool? = nil) {
        self.draft = draft
        self.isManual = isManual
        self.isAuthenticatedOverride = isAuthenticatedOverride
        defaultFriend = SplitwiseDefaultFriendStore.load()

        // A manual entry has no shortcut-supplied merchant/amount to resolve
        // against config — it starts blank on the last-used mode, with the
        // template list and default split friend ready for either mode.
        if isManual {
            let startMode = Self.loadLastManualMode()
            manualMode = startMode
            let config = WalletTransactionConfigStore.load()
            availableTemplates = Array(config.templates.keys)
            if let defaultFriend {
                selectedFriendId = defaultFriend.id
            }
            splitwiseRuntimeChoice = startMode == .splitwise ? .always : .never
            return
        }

        // Resolved synchronously (local disk reads only) so the form's
        // defaults are in place on the very first render — no need to wait
        // on a `.task` for this part.
        switch draft.payload {
        case .ynabWallet(let merchant, _, let card):
            let config = WalletTransactionConfigStore.load()
            availableTemplates = Array(config.templates.keys)

            var resolvedTemplateFriend: (id: Int, firstName: String, fullName: String)?
            if let info = config.resolvedMerchantInfo(for: merchant) {
                templateChoice = info.templateName
                payeeText = info.payeeName
                let template = config.templates[info.templateName]
                selectedCategoryId = template?.categoryId
                splitwiseRuntimeChoice = (template?.splitwiseOption ?? .never).splitRuntimeChoice
                resolvedTemplateFriend = template?.splitwiseFriend
            } else {
                payeeText = merchant
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
            // Splitwise-primary flow: an initial split choice of "always"
            // matches the original Splitwise draft view's default.
            splitwiseRuntimeChoice = .always

            // `currentAccessToken` is a plain Keychain read (no network),
            // unlike YNAB's token check, so the auth gate can be settled up
            // front instead of behind a `.task`.
            let isAuthenticated = isAuthenticatedOverride ?? (SplitwiseAuthService.currentAccessToken != nil)
            guard isAuthenticated else {
                notAuthenticated = true
                return
            }

            let config = WalletTransactionConfigStore.load()
            availableTemplates = Array(config.templates.keys)

            if let info = config.resolvedMerchantInfo(for: merchant) {
                templateChoice = info.templateName
                payeeText = info.payeeName
                let template = config.templates[info.templateName]
                splitwiseRuntimeChoice = (template?.splitwiseOption ?? .never).splitRuntimeChoice
                if let friend = template?.splitwiseFriend {
                    templateHasFriend = true
                    templateFriend = SplitwiseFriendEntity(templateFriend: friend)
                    selectedFriendId = friend.id
                }
            } else {
                payeeText = merchant
            }
        }
    }

    // MARK: Derived state

    var mode: Mode {
        if isManual { return manualMode }
        if case .ynabWallet = draft.payload { return .ynab }
        return .splitwise
    }

    /// For a manual entry, whether the *currently selected* mode's service
    /// is connected — drives the NotConnectedView gate reactively so the
    /// nav-bar menu can switch modes without a stored auth flag.
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
        // A template can carry a non-.never split setting from before
        // Splitwise was disconnected — treat as "never split" for this run
        // (YNAB draft) rather than showing a picker with nothing behind it.
        // A Splitwise draft is always Splitwise-authed by the time it shows.
        if mode == .ynab, !splitwiseAuth.isAuthenticated { return .never }
        return splitwiseRuntimeChoice ?? .never
    }

    /// Parsed amount for a manual entry — nil while the field is empty or
    /// not yet a positive number. Unused for shortcut-started drafts.
    var manualAmount: Double? {
        guard let parsed = try? AmountParser.parse(amountText), parsed > 0 else { return nil }
        return parsed
    }

    var canSubmit: Bool {
        if isManual, manualAmount == nil { return false }
        if payeeText.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        switch mode {
        case .ynab:
            if selectedAccountId == nil { return false }
            if splitwiseAuth.isAuthenticated, splitwiseRuntimeChoice == nil { return false }
            if resolvedSplitwiseAction != .never, selectedFriendId == nil && defaultFriend == nil { return false }
            if resolvedSplitwiseAction == .manual, Double(ownShareText) == nil { return false }
        case .splitwise:
            if selectedFriendId == nil && defaultFriend == nil { return false }
            if splitwiseRuntimeChoice == nil { return false }
            if resolvedSplitwiseAction == .manual, Double(ownShareText) == nil { return false }
        }
        return true
    }

    /// Label for the friend row's unset option — "Default (…)" when an
    /// app-wide default Splitwise friend applies, otherwise "None".
    var friendNoneLabel: String {
        defaultFriend.map { "Default (\($0.firstName))" } ?? "None"
    }

    var friendRowIsIncomplete: Bool {
        !templateHasFriend && selectedFriendId == nil && defaultFriend == nil
    }

    var resolvedFriendName: String? {
        templateHasFriend ? templateFriend?.fullName : nil
    }

    // MARK: Manual mode

    /// Switches a manual entry's mode, persisting the choice and resetting
    /// the split default to match each mode's convention (YNAB doesn't
    /// split by default, Splitwise-primary always does).
    func setManualMode(_ newMode: Mode) {
        guard newMode != manualMode else { return }
        withAnimation { manualMode = newMode }
        Self.saveLastManualMode(newMode)
        splitwiseRuntimeChoice = newMode == .splitwise ? .always : .never
    }

    /// Persists/restores the last-used manual mode so the "+" button reopens
    /// on whichever the user left it on — same lightweight UserDefaults
    /// pattern SharedFileImportView uses for its last import destination.
    private static let lastManualModeKey = "lastManualTransactionMode"
    private static func loadLastManualMode() -> Mode {
        UserDefaults.standard.string(forKey: lastManualModeKey).flatMap(Mode.init(rawValue:)) ?? .ynab
    }
    private static func saveLastManualMode(_ mode: Mode) {
        UserDefaults.standard.set(mode.rawValue, forKey: lastManualModeKey)
    }

    // MARK: Template application

    /// Re-applies the fields a chosen template controls — category (YNAB
    /// only), the split option, and the cached friend — or resets to
    /// per-mode defaults when the selection is cleared ("Create New"). The
    /// only mode-specific bits are that YNAB owns the category and that a
    /// from-scratch entry defaults to splitting every time on Splitwise but
    /// never on YNAB.
    func applyTemplate(_ name: String?) {
        let config = WalletTransactionConfigStore.load()
        let template = name.flatMap { config.templates[$0] }
        withAnimation {
            if mode == .ynab {
                selectedCategoryId = template?.categoryId
            }
            if name == nil {
                splitwiseRuntimeChoice = mode == .splitwise ? .always : .never
            } else {
                splitwiseRuntimeChoice = (template?.splitwiseOption ?? .never).splitRuntimeChoice
            }
            if let friend = template?.splitwiseFriend {
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

    /// Refreshes `availableTemplates` and re-applies `name` after the
    /// template editor saves — keeps the picker and dependent fields in sync.
    func templateSaved(_ name: String) {
        let config = WalletTransactionConfigStore.load()
        availableTemplates = Array(config.templates.keys)
        templateChoice = name
        applyTemplate(name)
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

    /// A manual entry can switch between YNAB ("Both") and Splitwise at any
    /// time via the nav-bar menu, so load whatever each connected service
    /// needs up front — YNAB categories/accounts and Splitwise friends —
    /// instead of gating on the current mode.
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

        // The form (with its locally-resolved defaults from init) is already
        // on screen. This only checks auth and kicks off the category/
        // account/friend refreshes — each section owns its own spinner, so
        // nothing here blocks the rest of the form from being usable.
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

    // MARK: Submit

    /// Creates the transaction/expense. Returns `true` once the draft is
    /// complete and the view should dismiss; `false` leaves the form up
    /// (validation error, auth gate, or a failed write shown inline).
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
            amount = a
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

        let trimmedPayee = payeeText.trimmingCharacters(in: .whitespaces)
        guard !trimmedPayee.isEmpty else {
            errorMessage = "Payee name can't be empty."
            return false
        }
        let finalPayeeName = trimmedPayee
        let finalCategoryId = selectedCategoryId

        if !isManual, templateChoice == nil {
            // Creating a new template from payee name
            var template = config.templates[trimmedPayee] ?? WalletTransactionConfig.Template(categoryId: nil)
            template.categoryId = selectedCategoryId
            template.splitwiseOption = SplitwiseTemplateOption(splitRuntimeChoice: splitwiseRuntimeChoice)
            config.templates[trimmedPayee] = template
            config.merchants[merchant] = WalletTransactionConfig.MerchantInfo(payeeName: trimmedPayee, templateName: trimmedPayee)
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

        // Shared by the YNAB write and the Splitwise split (when there is
        // one) so the two fold into a single combined history entry.
        let groupId = (action != .never && friend != nil) ? UUID() : nil

        async let ynabOutcome = PendingSync.createYNABTransaction(transaction, token: token, summary: "\(formattedAmount) at \(finalPayeeName)", groupId: groupId)
        async let splitDialogFragment = createSplitIfNeeded(friend: friend, description: finalPayeeName, amount: amount, action: action, ownShare: ownShare, groupId: groupId)

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
        groupId: UUID?
    ) async -> String? {
        guard action != .never, let friend else { return nil }
        return await WalletAutomationDialog.splitDialogFragment(amount: amount, description: description, friend: friend, ownShare: ownShare, groupId: groupId)
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
            amount = a
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

        let trimmedDescription = payeeText.trimmingCharacters(in: .whitespaces)
        guard !trimmedDescription.isEmpty else {
            errorMessage = "Description can't be empty."
            return false
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
                return false
            }
            finalFriendId = match.id
            finalFriendFirstName = match.firstName
            finalFriendFullName = match.fullName
        }

        if !isManual, templateChoice == nil {
            // Creating new template
            var template = config.templates[finalTemplateName] ?? WalletTransactionConfig.Template()
            template.splitwiseFriendId = finalFriendId
            template.splitwiseFriendFirstName = finalFriendFirstName
            template.splitwiseFriendFullName = finalFriendFullName
            template.splitwiseOption = SplitwiseTemplateOption(splitRuntimeChoice: splitwiseRuntimeChoice)
            config.templates[finalTemplateName] = template
            config.merchants[merchant] = WalletTransactionConfig.MerchantInfo(payeeName: finalDescription, templateName: finalTemplateName)
            configChanged = true
        } else if !isManual, !templateHasFriend {
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
                friend: SplitwiseFriendEntity(id: finalFriendId, firstName: finalFriendFirstName, fullName: finalFriendFullName),
                ownShare: ownShare
            )
            TransactionDraftGuard.complete(draft.id)
            return true
        } catch {
            errorMessage = SplitwiseIntentError.message(for: error)
            return false
        }
    }
}
