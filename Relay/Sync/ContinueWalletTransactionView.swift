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
//  YNAB-only fields and shows just the split. Reads/writes the exact same
//  WalletTransactionConfigStore and calls the same PendingSync/
//  SplitwiseExpenseHelper the intents do — the only thing that differs is
//  asking the remaining questions via a SwiftUI form instead of
//  requestValue/requestDisambiguation.
//
//  Unlike the intents, this doesn't replicate auto-match patterns or
//  multi-merchant template linking — creating a template here just links
//  this one merchant, using the payee/description as the template name.
//  Anything fancier can still be set up afterwards in Templates.
//

import SwiftUI
import os

private let logger = Logger(subsystem: "com.octabits.relay", category: "ContinueWalletTransactionView")

struct ContinueWalletTransactionView: View {
    let draft: TransactionDraft

    @State private var ynabAuth = YNABAuthService()
    @State private var splitwiseAuth = SplitwiseAuthService()
    @State private var notAuthenticated = false
    @State private var errorMessage: String?
    @State private var isSubmitting = false
    @State private var showTemplateEditor = false
    @State private var showDiscardConfirmation = false
    @State private var editingTemplateName: String? = nil
    @Environment(\.dismiss) private var dismiss

    /// Payee (YNAB draft) or expense description (Splitwise draft).
    @State private var payeeText = ""
    /// Raw amount text — only used for a manual entry (isManual); a
    /// shortcut-started draft's amount comes fixed from the payload.
    @State private var amountText = ""
    /// Selected mode for a manual entry (isManual) — switchable via the
    /// nav-bar menu; ignored otherwise (mode comes from the payload).
    @State private var manualMode: Mode = .ynab
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

    /// True once the resolved template already has its own cached Splitwise
    /// friend — that takes precedence over the app-wide default
    /// (SplitwiseDefaultFriendStore) and is shown read-only rather than
    /// re-offered as a choice. Kept as a full entity (not just an id) so
    /// submit() can use it directly.
    @State private var templateHasFriend = false
    @State private var templateFriend: SplitwiseFriendEntity?

    private let defaultFriend: SplitwiseDefaultFriend?

    /// True when this is a from-scratch manual entry (the "+" button) rather
    /// than finishing a shortcut-started draft: the amount becomes an
    /// editable field instead of a fixed header, and none of the
    /// merchant/card/template auto-mapping (which only makes sense for a
    /// recognized shortcut merchant) is written back to config.
    let isManual: Bool

    /// Called when the user taps "Discard" — typically deletes the draft and
    /// dismisses. Nil hides the section entirely (e.g. manual entries).
    let onDiscard: (() -> Void)?

    /// Preview/testing seam only — nil (the default) always falls through to
    /// the real Keychain check. Lets `#Preview` render the form itself
    /// instead of racing the async "Not Connected" gate.
    let isAuthenticatedOverride: Bool?

    private enum Mode: String { case ynab, splitwise }
    private var mode: Mode {
        if isManual { return manualMode }
        if case .ynabWallet = draft.payload { return .ynab }
        return .splitwise
    }

    /// For a manual entry, whether the *currently selected* mode's service
    /// is connected — drives the NotConnectedView gate reactively so the
    /// nav-bar menu can switch modes without a stored auth flag.
    private var isModeAuthenticated: Bool {
        switch mode {
        case .ynab: ynabAuth.isAuthenticated
        case .splitwise: splitwiseAuth.isAuthenticated
        }
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

    private var manualModeBinding: Binding<Mode> {
        Binding(
            get: { manualMode },
            set: { newMode in
                guard newMode != manualMode else { return }
                withAnimation { manualMode = newMode }
                Self.saveLastManualMode(newMode)
                // Match each mode's split convention: YNAB defaults to no
                // split, Splitwise-primary to splitting every time.
                splitwiseRuntimeChoice = newMode == .splitwise ? .always : .never
            }
        )
    }

    init(draft: TransactionDraft, isManual: Bool = false, onDiscard: (() -> Void)? = nil, isAuthenticatedOverride: Bool? = nil) {
        self.draft = draft
        self.isManual = isManual
        self.onDiscard = onDiscard
        self.isAuthenticatedOverride = isAuthenticatedOverride
        defaultFriend = SplitwiseDefaultFriendStore.load()

        // A manual entry has no shortcut-supplied merchant/amount to resolve
        // against config — it starts blank on the last-used mode, with the
        // template list and default split friend ready for either mode.
        if isManual {
            let startMode = Self.loadLastManualMode()
            _manualMode = State(initialValue: startMode)
            let config = WalletTransactionConfigStore.load()
            _availableTemplates = State(initialValue: Array(config.templates.keys))
            if let defaultFriend {
                _selectedFriendId = State(initialValue: defaultFriend.id)
            }
            _splitwiseRuntimeChoice = State(initialValue: startMode == .splitwise ? .always : .never)
            return
        }

        // Resolved synchronously (local disk reads only) so the form's
        // defaults are in place on the very first render — no need to wait
        // on a `.task` for this part.
        switch draft.payload {
        case .ynabWallet(let merchant, _, let card):
            let config = WalletTransactionConfigStore.load()
            _availableTemplates = State(initialValue: Array(config.templates.keys))

            var resolvedTemplateFriend: (id: Int, firstName: String, fullName: String)?
            if let info = config.resolvedMerchantInfo(for: merchant) {
                _templateChoice = State(initialValue: info.templateName)
                _payeeText = State(initialValue: info.payeeName)
                let template = config.templates[info.templateName]
                _selectedCategoryId = State(initialValue: template?.categoryId)
                _splitwiseRuntimeChoice = State(initialValue: Self.runtimeChoice(for: template?.splitwiseOption ?? .never))
                resolvedTemplateFriend = template?.splitwiseFriend
            } else {
                _payeeText = State(initialValue: merchant)
            }

            if let accountId = config.cards[card] {
                _accountResolved = State(initialValue: true)
                _selectedAccountId = State(initialValue: accountId)
            }

            if let resolvedTemplateFriend {
                _templateHasFriend = State(initialValue: true)
                _templateFriend = State(initialValue: SplitwiseFriendEntity(id: resolvedTemplateFriend.id, firstName: resolvedTemplateFriend.firstName, fullName: resolvedTemplateFriend.fullName))
                _selectedFriendId = State(initialValue: resolvedTemplateFriend.id)
            } else if let defaultFriend {
                _selectedFriendId = State(initialValue: defaultFriend.id)
            }

        case .splitwiseWallet(let merchant, _, _):
            if let ownShare = draft.ownShare {
                _ownShareText = State(initialValue: String(ownShare))
            }
            // Splitwise-primary flow: an initial split choice of "always"
            // matches the original Splitwise draft view's default.
            _splitwiseRuntimeChoice = State(initialValue: .always)

            // `currentAccessToken` is a plain Keychain read (no network),
            // unlike YNAB's token check, so the auth gate can be settled up
            // front instead of behind a `.task`.
            let isAuthenticated = isAuthenticatedOverride ?? (SplitwiseAuthService.currentAccessToken != nil)
            guard isAuthenticated else {
                _notAuthenticated = State(initialValue: true)
                return
            }

            let config = WalletTransactionConfigStore.load()
            _availableTemplates = State(initialValue: Array(config.templates.keys))

            if let info = config.resolvedMerchantInfo(for: merchant) {
                _templateChoice = State(initialValue: info.templateName)
                _payeeText = State(initialValue: info.payeeName)
                let template = config.templates[info.templateName]
                _splitwiseRuntimeChoice = State(initialValue: Self.runtimeChoice(for: template?.splitwiseOption ?? .never))
                if let friend = template?.splitwiseFriend {
                    _templateHasFriend = State(initialValue: true)
                    _templateFriend = State(initialValue: SplitwiseFriendEntity(id: friend.id, firstName: friend.firstName, fullName: friend.fullName))
                    _selectedFriendId = State(initialValue: friend.id)
                }
            } else {
                _payeeText = State(initialValue: merchant)
            }
        }
    }

    private var cardName: String {
        if case .ynabWallet(_, _, let card) = draft.payload, !card.isEmpty { return card }
        return "Account"
    }

    private var resolvedSplitwiseAction: SplitwiseSplitOption {
        // A template can carry a non-.never split setting from before
        // Splitwise was disconnected — treat as "never split" for this run
        // (YNAB draft) rather than showing a picker with nothing behind it.
        // A Splitwise draft is always Splitwise-authed by the time it shows.
        if mode == .ynab, !splitwiseAuth.isAuthenticated { return .never }
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

    /// Parsed amount for a manual entry — nil while the field is empty or
    /// not yet a positive number. Unused for shortcut-started drafts.
    private var manualAmount: Double? {
        guard let parsed = try? AmountParser.parse(amountText), parsed > 0 else { return nil }
        return parsed
    }

    private var canSubmit: Bool {
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

    var body: some View {
        Group {
            if isManual ? !isModeAuthenticated : notAuthenticated {
                switch mode {
                case .ynab: NotConnectedView(service: "YNAB", connect: ynabAuth.signIn)
                case .splitwise: NotConnectedView(service: "Splitwise", connect: splitwiseAuth.signIn)
                }
            } else {
                content
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isManual {
                ToolbarItem(placement: .principal) {
                    Menu {
                        Picker("Type", selection: manualModeBinding) {
                            Text("Both").tag(Mode.ynab)
                            Text("Splitwise").tag(Mode.splitwise)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(mode == .ynab ? "Both" : "Splitwise")
                                .fontWeight(.semibold)
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                        }
                        .foregroundStyle(Color.foregroundColor)
                    }
                }
            }
        }
        .task { await load() }
        .onAuthenticated(mode == .ynab ? ynabAuth.isAuthenticated : splitwiseAuth.isAuthenticated) {
            notAuthenticated = false
            Task { await load() }
        }
    }

    private var content: some View {
        List {
            Section {
                if isManual {
                    manualAmountField
                } else {
                    TransactionDraftHeader(amount: draft.formattedAmount, merchant: draft.merchant, startedAt: draft.startedAt)
                }
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.sheetBackgroundColor)

            Section {
                templateRow

                DraftDetailRow(
                    icon: "text.alignleft",
                    title: mode == .ynab ? "Payee" : "Description",
                    isIncomplete: payeeText.trimmingCharacters(in: .whitespaces).isEmpty
                ) {
                    TextField(mode == .ynab ? "Payee Name" : "Description", text: $payeeText)
                        .multilineTextAlignment(.trailing)
                        .submitLabel(.done)
                }
                .cardRowBackground()

                if mode == .ynab {
                    accountRow
                    categoryRow
                } else {
                    // Splitwise-primary: friend/split/share live alongside
                    // the description since they *are* the transaction.
                    friendRow
                    splitPickerRow
                    if resolvedSplitwiseAction == .manual {
                        ownShareRow
                    }
                }
            }

            if mode == .ynab, splitwiseAuth.isAuthenticated {
                Section("Split") {
                    splitPickerRow
                    if resolvedSplitwiseAction != .never {
                        friendRow
                    }
                    if resolvedSplitwiseAction == .manual {
                        ownShareRow
                    }
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
                .listRowBackground(Color.sheetBackgroundColor)
            }

            if onDiscard != nil {
                Section {
                    Button("Discard") {
                        showDiscardConfirmation = true
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .confirmationDialog(
                        "Discard this draft?",
                        isPresented: $showDiscardConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("Confirm", role: .destructive, action: onDiscard!)
                    }
                }
                .cardRowBackground()
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
                title: mode == .ynab ? "Add Transaction" : "Add Expense",
                isLoading: isSubmitting,
                isDisabled: !canSubmit || isSubmitting
            ) {
                Task { await submit() }
            }
        }
    }

    // MARK: - Rows

    private var manualAmountField: some View {
        TextField("0", text: $amountText)
            .keyboardType(.decimalPad)
            .multilineTextAlignment(.center)
            .foregroundStyle(Color.foregroundColor)
            .fontWeight(.heavy)
            .font(.system(size: 50))
            .minimumScaleFactor(0.5)
            .frame(maxWidth: .infinity)
    }

    private var templateRow: some View {
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
    }

    private var accountRow: some View {
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
    }

    private var categoryRow: some View {
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

    private var friendRow: some View {
        SplitwiseFriendPickerRow(
            resolvedFriendName: templateHasFriend ? templateFriend?.fullName : nil,
            isLoading: isLoadingFriends,
            friends: friends,
            selectedFriendId: $selectedFriendId,
            noneLabel: defaultFriend.map { "Default (\($0.firstName))" } ?? "None",
            isIncomplete: !templateHasFriend && selectedFriendId == nil && defaultFriend == nil
        )
    }

    private var splitPickerRow: some View {
        SplitwiseSplitPickerRow(
            choice: $splitwiseRuntimeChoice,
            isIncomplete: splitwiseRuntimeChoice == nil
        )
    }

    private var ownShareRow: some View {
        SplitwiseOwnShareRow(ownShareText: $ownShareText, isIncomplete: Double(ownShareText) == nil)
    }

    // MARK: - Template application

    private func applyTemplate(_ name: String?) {
        switch mode {
        case .ynab: applyTemplateYNAB(name)
        case .splitwise: applyTemplateSplitwise(name)
        }
    }

    private func applyTemplateYNAB(_ name: String?) {
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

    private func applyTemplateSplitwise(_ name: String?) {
        let config = WalletTransactionConfigStore.load()
        guard let name else {
            withAnimation {
                splitwiseRuntimeChoice = .always
                templateHasFriend = false
                templateFriend = nil
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
                templateFriend = SplitwiseFriendEntity(id: newFriend.id, firstName: newFriend.firstName, fullName: newFriend.fullName)
                selectedFriendId = newFriend.id
            } else {
                templateHasFriend = false
                templateFriend = nil
                selectedFriendId = SplitwiseDefaultFriendStore.load()?.id
            }
        }
    }

    // MARK: - Loading

    private func load() async {
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

    // MARK: - Submit

    private func submit() async {
        switch mode {
        case .ynab: await submitYNAB()
        case .splitwise: await submitSplitwise()
        }
    }

    private func submitYNAB() async {
        let merchant: String
        let card: String
        let amount: Double
        if isManual {
            merchant = ""
            card = ""
            amount = manualAmount ?? 0
        } else {
            guard case .ynabWallet(let m, let a, let c) = draft.payload else { return }
            merchant = m
            card = c
            amount = a
        }
        guard let token = await YNABAuthService.validAccessToken() else {
            notAuthenticated = true
            return
        }
        errorMessage = nil
        isSubmitting = true
        defer { isSubmitting = false }

        var config = WalletTransactionConfigStore.load()
        var configChanged = false

        let trimmedPayee = payeeText.trimmingCharacters(in: .whitespaces)
        guard !trimmedPayee.isEmpty else {
            errorMessage = "Payee name can't be empty."
            return
        }
        let finalPayeeName = trimmedPayee
        let finalCategoryId = selectedCategoryId

        if !isManual, templateChoice == nil {
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
        ownShare: Double?,
        groupId: UUID?
    ) async -> String? {
        guard action != .never, let friend else { return nil }
        return await WalletAutomationDialog.splitDialogFragment(amount: amount, description: description, friend: friend, ownShare: ownShare, groupId: groupId)
    }

    private func submitSplitwise() async {
        let merchant: String
        let amount: Double
        if isManual {
            merchant = ""
            amount = manualAmount ?? 0
        } else {
            guard case .splitwiseWallet(let m, let a, _) = draft.payload else { return }
            merchant = m
            amount = a
        }
        guard SplitwiseAuthService.currentAccessToken != nil else {
            notAuthenticated = true
            return
        }
        errorMessage = nil
        isSubmitting = true
        defer { isSubmitting = false }

        var config = WalletTransactionConfigStore.load()
        var configChanged = false

        let trimmedDescription = payeeText.trimmingCharacters(in: .whitespaces)
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

        if !isManual, templateChoice == nil {
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
