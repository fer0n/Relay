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
    enum Mode: String { case ynab, ledger }

    // MARK: Inputs

    let draft: TransactionDraft

    /// From-scratch entry rather than finishing a shortcut-started draft, so
    /// nothing is written back to the merchant/card/template config.
    let isManual: Bool

    let isPrefilled: Bool
    let isAuthenticatedOverride: Bool?

    private let defaultTarget: WalletTransactionConfig.CachedSplitTarget?
    /// Wins over both a template's cached target and the app-wide default —
    /// e.g. "Add Transaction" from a specific person's page. See the
    /// equivalent precedence in AddLedgerExpenseIntent.resolveTarget.
    private let friendOverride: SplitTargetEntity?

    // MARK: Services / status

    let ynabAuth = YNABAuthService()
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

    var splitRuntimeChoice: SplitChoice? = .never
    /// Which ledger the split books on, and who on it.
    var ledgerZoneName: String?
    var ledgerParticipantIDs: [String] = []
    var ownShareText = ""
    /// `.shares` only — relative weights, reset to an even 1 each per form,
    /// since they describe this transaction rather than a setting.
    var ownWeightText = "1"
    /// Keyed by `SplitParticipant.id`; a missing entry is an unedited `1`.
    var participantWeightTexts: [String: String] = [:]

    /// Seeds the picker from a target that came from a template, a Shortcuts
    /// override or the app-wide default. A stored participant means that
    /// person; none means the whole ledger, which `seedLedgerDefaults` fills in
    /// once it's loaded.
    private func applySplitTarget(_ entity: SplitTargetEntity?) {
        ledgerZoneName = entity?.zoneName
        ledgerParticipantIDs = entity?.participantID.map { [$0] } ?? []
    }

    /// `preferred` when there is one, otherwise the app-wide default.
    private func applySplitTarget(preferring preferred: SplitTargetEntity?) {
        applySplitTarget(preferred ?? defaultTarget.map(SplitTargetEntity.init(cachedTarget:)))
    }

    // MARK: Init

    init(draft: TransactionDraft, isManual: Bool = false, prefill: TransactionHistoryEntry? = nil, isAuthenticatedOverride: Bool? = nil, friendOverride: SplitTargetEntity? = nil) {
        self.draft = draft
        self.isManual = isManual
        self.isPrefilled = prefill != nil
        self.isAuthenticatedOverride = isAuthenticatedOverride
        self.friendOverride = friendOverride
        defaultTarget = DefaultSplitTargetStore.load()

        if isManual {
            let startMode = friendOverride != nil
                ? Mode.ledger
                : prefill.map { $0.service == .ledger ? Mode.ledger : Mode.ynab }
                    ?? Self.resolveManualMode(ynabAuthenticated: ynabAuth.isAuthenticated, canSplit: SplitAvailability.canSplit)
            manualMode = startMode
            let config = WalletTransactionConfigStore.load()
            availableTemplates = Array(config.templates.keys)
            cachedTemplatePayeeNames = Self.payeeNamesByTemplate(config)
            applySplitTarget(preferring: friendOverride)
            if let prefill {
                applyPrefill(prefill, config: config)
            } else {
                selectedAccountId = Self.loadLastManualAccountId()
                splitRuntimeChoice = Self.loadLastSplitChoice() ?? (startMode == .ledger ? .always : .never)
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

            var resolvedTemplateFriend: WalletTransactionConfig.CachedSplitTarget?
            if let info = config.resolvedMerchantInfo(for: merchant) {
                templateChoice = info.templateName
                payeeText = info.payeeName
                let template = config.templates[info.templateName]
                selectedCategoryId = template?.categoryId
                // Never the global last-used choice, which would let the last
                // manual entry's pick spill into this draft.
                splitRuntimeChoice = (template?.splitOption ?? .never).splitRuntimeChoice.map(SplitChoice.init)
                resolvedTemplateFriend = template?.splitTarget
            } else {
                payeeText = merchant
                // No template to carry a split default, so canSubmit's nil
                // check forces an explicit pick.
                splitRuntimeChoice = nil
            }

            if let accountId = config.cards[card] {
                accountResolved = true
                selectedAccountId = accountId
            }

            applySplitTarget(preferring: resolvedTemplateFriend.map(SplitTargetEntity.init(cachedTarget:)))

        case .ledgerWallet(let merchant, _, _):
            if let ownShare = draft.ownShare {
                ownShareText = String(ownShare)
            }
            splitRuntimeChoice = .always

            // A plain Keychain read (no network), unlike YNAB's token check, so
            // the auth gate settles here instead of behind a `.task`.
            let isAuthenticated = isAuthenticatedOverride ?? (SplitAvailability.canSplit)
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
                splitRuntimeChoice = (template?.splitOption ?? .never).splitRuntimeChoice.map(SplitChoice.init)
                if let friend = template?.splitTarget {
                    applySplitTarget(SplitTargetEntity(cachedTarget: friend))
                }
            } else {
                // No template to carry a split default, so canSubmit's nil
                // check forces an explicit pick.
                splitRuntimeChoice = nil
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
        case .ledgerExpense(let expense):
            amountText = (Double(expense.costCents) / Const.centsPerUnit).asMoneyString
            payeeText = expense.title
        }

        // Assigned directly rather than via applyTemplate(): the fields a
        // template would push are already seeded from the entry, which is what
        // a re-add should reproduce.
        templateChoice = config.templateName(forPayeeName: payeeText, merchant: entry.merchant)

        // The split half of the entry, whether it was the whole thing or rode
        // alongside a YNAB transaction.
        let splitExpense: LedgerExpenseRequest?
        if let ledgerExpense = entry.split?.ledgerExpense {
            splitExpense = ledgerExpense
        } else if case .ledgerExpense(let expense) = entry.payload {
            splitExpense = expense
        } else {
            splitExpense = nil
        }
        guard let splitExpense else { return }

        applySplitTarget(SplitTargetEntity(
            zoneName: splitExpense.zoneName,
            firstName: splitExpense.ledgerName,
            fullName: splitExpense.ledgerName
        ))
        // Re-adds bill exactly who the original did, rather than everyone
        // currently on the ledger — someone may have joined since.
        ledgerParticipantIDs = splitExpense.others.map(\.participantID)

        // An even split reproduces as "Split Equally" so re-adding it follows a
        // changed amount, rather than freezing yesterday's cents into a manual
        // share.
        let payerOwed = splitExpense.payer?.owedCents ?? 0
        let evenSplit = SplitAllocation.equal.owedCents(
            totalCents: splitExpense.costCents,
            participantCount: splitExpense.others.count
        )
        if payerOwed == evenSplit?.first {
            splitRuntimeChoice = .always
        } else {
            splitRuntimeChoice = .manual
            ownShareText = String(Double(payerOwed) / Const.centsPerUnit)
        }
    }

    // MARK: Derived state

    var mode: Mode {
        if isManual { return manualMode }
        if case .ynabWallet = draft.payload { return .ynab }
        return .ledger
    }

    var isModeAuthenticated: Bool {
        switch mode {
        case .ynab: ynabAuth.isAuthenticated
        case .ledger: SplitAvailability.canSplit
        }
    }

    var cardName: String {
        if case .ynabWallet(_, _, let card) = draft.payload, !card.isEmpty { return card }
        return "Account"
    }

    var resolvedSplitAction: SplitChoice {
        // A template can carry a non-.never setting from before splitting was
        // disconnected; don't show a picker with nothing behind it.
        if mode == .ynab, !SplitAvailability.canSplit { return .never }
        return splitRuntimeChoice ?? .never
    }

    var manualAmount: Double? {
        guard let parsed = try? AmountParser.parse(amountText), parsed > 0 else { return nil }
        return parsed
    }

    /// Whether the amount is a typed-in field rather than the fixed header.
    var amountIsEditable: Bool {
        isManual || draft.receivedNoValues
    }

    /// The amount a split is worked out against — the same value `submit()`
    /// books, so the share rows can't show numbers the write disagrees with.
    /// Nil while a typed amount is unparseable.
    var splitAmount: Double? {
        amountIsEditable ? manualAmount : draft.amount
    }

    /// Everyone the split is with, in the order their `.shares` rows appear.
    var splitParticipants: [SplitParticipant] {
        resolvedSplitTarget?.participants ?? []
    }

    /// A `.shares` weight, defaulting to an even 1 for anyone not edited yet.
    func weightText(for participantId: String) -> String {
        participantWeightTexts[participantId] ?? "1"
    }

    func setWeightText(_ text: String, for participantId: String) {
        participantWeightTexts[participantId] = text
    }

    /// The `.shares` weights as `[yours, theirs…]`, in `splitParticipants`
    /// order. Nil if any of them is unparseable.
    private var shareWeights: [Double]? {
        guard let mine = SplitShareMath.cents(ownWeightText) else { return nil }
        var weights = [Double(mine)]
        for participant in splitParticipants {
            guard let weight = SplitShareMath.cents(weightText(for: participant.id)) else { return nil }
            weights.append(Double(weight))
        }
        return weights
    }

    /// The chosen split as an allocation, or nil while its own inputs can't be
    /// read — an unparseable own share, a bad weight.
    private var currentAllocation: SplitAllocation? {
        switch resolvedSplitAction {
        case .always, .never:
            return .equal
        case .manual:
            guard let own = Double(ownShareText) else { return nil }
            return .ownShare(cents: Int((own * Const.centsPerUnit).rounded()))
        case .shares:
            return shareWeights.map { .weights($0) }
        }
    }

    /// What everyone ends up owing, in whole cents, as `[yours, theirs…]`. Nil
    /// while the split can't be worked out.
    private func splitOwedCents(amount: Double) -> [Int]? {
        guard let currentAllocation, !splitParticipants.isEmpty else { return nil }
        return currentAllocation.owedCents(
            totalCents: SplitShareMath.cents(fromAmount: amount),
            participantCount: splitParticipants.count
        )
    }

    /// What a `.shares` split books as your own share, i.e. what the `.manual`
    /// field would have been typed as.
    func sharesOwnShare(amount: Double) -> Double? {
        splitOwedCents(amount: amount).map { Double($0[0]) / Const.centsPerUnit }
    }

    /// Labels under the `.shares` weight fields. Nil while the amount or a
    /// weight can't be read.
    var ownShareAmountText: String? {
        splitAmount.flatMap { splitOwedCents(amount: $0) }.map { SplitShareMath.text(fromCents: $0[0]) }
    }

    func shareAmountText(for participantId: String) -> String? {
        guard let index = splitParticipants.firstIndex(where: { $0.id == participantId }),
              let amount = splitAmount,
              let owed = splitOwedCents(amount: amount) else { return nil }
        return SplitShareMath.text(fromCents: owed[index + 1])
    }

    var canSubmit: Bool {
        if amountIsEditable, manualAmount == nil { return false }
        switch mode {
        case .ynab:
            if payeeText.trimmingCharacters(in: .whitespaces).isEmpty { return false }
            if selectedAccountId == nil { return false }
            // No auto-create/uncategorized path here, unlike the split side's.
            if templateChoice == nil { return false }
            if selectedCategoryId == nil { return false }
            if SplitAvailability.canSplit, splitRuntimeChoice == nil { return false }
            if resolvedSplitAction != .never, resolvedSplitTarget == nil { return false }
            if !splitInputsValid { return false }
        case .ledger:
            if splitEntryDescription.isEmpty { return false }
            if resolvedSplitTarget == nil { return false }
            if splitRuntimeChoice == nil { return false }
            if !splitInputsValid { return false }
        }
        return true
    }

    /// Whether the chosen split mode's own inputs are usable — a typed own
    /// share for `.manual`, weights that add up to something for `.shares`.
    private var splitInputsValid: Bool {
        switch resolvedSplitAction {
        case .always, .never:
            return true
        case .manual:
            return Double(ownShareText) != nil
        case .shares:
            guard let amount = splitAmount else { return false }
            return splitOwedCents(amount: amount) != nil
        }
    }

    /// Replaces who's on the split too: the previous ledger's participant ids
    /// mean nothing on this one.
    func selectLedger(_ ledger: Ledger) {
        ledgerZoneName = ledger.zoneName
        ledgerParticipantIDs = ledger.others.map(\.id)
    }

    /// Empty means the form offers no Split section at all.
    var availableLedgers: [Ledger] { LedgerStore.shared.sharedLedgers }

    var canSplit: Bool { !availableLedgers.isEmpty }

    var selectedLedger: Ledger? {
        availableLedgers.first { $0.zoneName == ledgerZoneName }
    }

    /// Flags the row whenever the split can't be booked — nobody picked and no
    /// default to stand in, but also a group whose members have all been
    /// removed, which reads as filled in while billing no one.
    var friendRowIsIncomplete: Bool {
        resolvedSplitTarget == nil
    }

    /// Who the split will actually be booked against. An empty selection is the
    /// picker's "Default (…)" state — a real choice, not a missing one — so the
    /// app-wide default resolves here rather than being rejected at submit.
    /// Everyone ticked on the chosen ledger. There's no app-wide default to
    /// fall back on here and no cache that can be cold — the participants come
    /// from the share itself — so this is either complete or nil.
    var resolvedSplitTarget: SplitTarget? {
        guard let ledger = LedgerStore.shared.ledgers.first(where: { $0.zoneName == ledgerZoneName }) else { return nil }
        let picked = ledger.others.filter { ledgerParticipantIDs.contains($0.id) }
        guard !picked.isEmpty else { return nil }
        return SplitTarget(
            participants: picked.map(SplitParticipant.init),
            zoneName: ledger.zoneName,
            // Named only when the whole ledger is on the split — billing a
            // subset is a split with those people, not with the ledger.
            ledgerName: picked.count == ledger.others.count ? ledger.name : nil
        )
    }

    var ynabPayeeName: String {
        payeeText.trimmingCharacters(in: .whitespaces)
    }

    var ynabMemo: String? {
        let trimmed = memoText.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Description for the split half of a `.ynab`-mode transaction.
    var splitDescription: String {
        guard let ynabMemo else { return ynabPayeeName }
        return "\(ynabPayeeName): \(ynabMemo)"
    }

    var splitPayeeName: String {
        let typed = payeeText.trimmingCharacters(in: .whitespaces)
        return typed.isEmpty ? draft.merchant : typed
    }

    /// What a split-primary draft calls the expense: whatever was typed into
    /// Description, falling back to the payee. Distinct from `splitDescription`
    /// above, which is the *YNAB* half's payee+memo handed to a side-split.
    /// Doubles as the Description field's placeholder.
    var splitEntryDescription: String {
        let typed = descriptionText.trimmingCharacters(in: .whitespaces)
        return typed.isEmpty ? splitPayeeName : typed
    }

    // MARK: Manual mode

    func setManualMode(_ newMode: Mode) {
        guard newMode != manualMode else { return }
        withAnimation { manualMode = newMode }
        Self.saveLastManualMode(newMode)
        splitRuntimeChoice = newMode == .ledger ? .always : .never
    }

    private static let lastManualModeKey = "lastManualTransactionMode"
    private static func loadLastManualMode() -> Mode? {
        UserDefaults.standard.string(forKey: lastManualModeKey).flatMap(Mode.init(rawValue:))
    }

    /// With one service connected that one wins over the last-used mode, so a
    /// split-only user never lands on a "Connect YNAB" dead end.
    private static func resolveManualMode(ynabAuthenticated: Bool, canSplit: Bool) -> Mode {
        if ynabAuthenticated && canSplit {
            return loadLastManualMode() ?? .ynab
        }
        return canSplit ? .ledger : .ynab
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
    func setSplitRuntimeChoice(_ choice: SplitChoice?) {
        splitRuntimeChoice = choice
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
    private static func loadLastSplitChoice() -> SplitChoice? {
        UserDefaults.standard.string(forKey: lastSplitChoiceKey).flatMap(SplitChoice.init(rawValue:))
    }
    private static func saveLastSplitChoice(_ choice: SplitChoice?) {
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
                    splitRuntimeChoice = Self.loadLastSplitChoice() ?? (mode == .ledger ? .always : .never)
                } else {
                    splitRuntimeChoice = Self.loadLastSplitChoice()
                        ?? (template?.splitOption ?? .never).splitRuntimeChoice.map(SplitChoice.init)
                }
            } else {
                // Drafts never read the global last-used choice: follow the
                // picked template's option, or stay unset to force a pick.
                splitRuntimeChoice = name == nil
                    ? nil
                    : (template?.splitOption ?? .never).splitRuntimeChoice.map(SplitChoice.init)
            }
            applySplitTarget(
                preferring: friendOverride ?? template?.splitTarget.map(SplitTargetEntity.init(cachedTarget:))
            )
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
        // Unconditional: the form has to know whether there's a ledger before
        // it can decide whether to offer the destination row at all, and a
        // non-forced refresh is a no-op when the snapshot is fresh.
        await LedgerStore.shared.refresh(force: false)
        seedLedgerDefaults()

        // A manual entry can switch modes at any time, so YNAB loads either
        // way; the ledger side is already seeded above.
        if isManual {
            await loadManualYNAB()
            return
        }
        // The ledger case needs nothing more: `load()` has already refreshed
        // the store and seeded the picker from it.
        if case .ynab = mode { await loadYNAB() }
    }

    /// Picks a ledger to start on, and fills in its participants — splitting
    /// with everyone on it is the common case.
    private func seedLedgerDefaults() {
        if ledgerZoneName == nil {
            ledgerZoneName = availableLedgers.first?.zoneName
        }
        if ledgerParticipantIDs.isEmpty, let ledger = selectedLedger {
            ledgerParticipantIDs = ledger.others.map(\.id)
        }
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
        _ = await (categoriesTask, accountsTask)
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

    // MARK: Submit

    /// `true` means the view should dismiss; `false` leaves the form up with an
    /// inline error or auth gate.
    func submit() async -> Bool {
        switch mode {
        case .ynab: await submitYNAB()
        case .ledger: await submitSplit()
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

        let choice = resolvedSplitAction
        let action = choice.submitOption

        // `let`, not `var`: captured by the `async let` below, where a mutable
        // var trips Swift 6 strict concurrency checking.
        let allocation: SplitAllocation
        switch resolveAllocation(for: choice, amount: amount) {
        case .valid(let resolved): allocation = resolved
        case .invalid(let message):
            errorMessage = message
            return false
        }

        let target: SplitTarget?
        if action != .never {
            guard let resolved = resolvedSplitTarget else {
                errorMessage = "Pick someone to split with."
                return false
            }
            target = resolved
        } else {
            target = nil
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
        let groupId = (action != .never && target != nil) ? UUID() : nil

        async let ynabOutcome = PendingSync.createYNABTransaction(transaction, token: token, summary: "\(formattedAmount) at \(finalPayeeName)", groupId: groupId, merchant: isManual ? nil : merchant)
        async let splitDialogFragment = createSplitIfNeeded(target: target, description: splitDescription, amount: amount, action: action, allocation: allocation, groupId: groupId, merchant: isManual ? nil : merchant)

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

    private enum AllocationResolution {
        case valid(SplitAllocation)
        case invalid(String)
    }

    /// How the chosen mode divides the cost: evenly, by the typed own share for
    /// `.manual`, or by the weights for `.shares`.
    private func resolveAllocation(for choice: SplitChoice, amount: Double) -> AllocationResolution {
        switch choice {
        case .always, .never:
            return .valid(.equal)
        case .manual:
            switch SplitExpenseService.parseOwnShare(ownShareText, amount: amount) {
            case .valid(let parsed): return .valid(.ownShare(cents: Int((parsed * Const.centsPerUnit).rounded())))
            case .invalid(let message): return .invalid(message)
            }
        case .shares:
            guard let weights = shareWeights, weights.reduce(0, +) > 0 else {
                return .invalid(String(localized: "Give at least one of you a share."))
            }
            return .valid(.weights(weights))
        }
    }

    private func createSplitIfNeeded(
        target: SplitTarget?,
        description: String,
        amount: Double,
        action: SplitOption,
        allocation: SplitAllocation,
        groupId: UUID?,
        merchant: String?
    ) async -> String? {
        guard action != .never, let target else { return nil }
        return await WalletAutomationDialog.splitDialogFragment(amount: amount, description: description, target: target, allocation: allocation, groupId: groupId, merchant: merchant).fragment
    }

    private func submitSplit() async -> Bool {
        let merchant: String
        let amount: Double
        if isManual {
            merchant = ""
            amount = manualAmount ?? 0
        } else {
            guard case .ledgerWallet(let m, let a, _) = draft.payload else { return false }
            merchant = m
            amount = draft.receivedNoValues ? (manualAmount ?? 0) : a
        }
        guard SplitAvailability.canSplit else {
            notAuthenticated = true
            return false
        }
        errorMessage = nil
        isSubmitting = true
        defer { isSubmitting = false }

        var config = WalletTransactionConfigStore.load()
        var configChanged = false

        let finalDescription = splitEntryDescription
        guard !finalDescription.isEmpty else {
            errorMessage = "Description can't be empty."
            return false
        }
        let finalPayeeName = splitPayeeName
        let finalTemplateName: String
        if let templateChoice {
            finalTemplateName = templateChoice
        } else if !isManual {
            // An untemplated draft goes under the default template rather than
            // spawning a per-payee one, matching the intent's flow.
            finalTemplateName = config.ensureSplitDefaultTemplate()
        } else {
            finalTemplateName = finalPayeeName
        }

        guard let target = resolvedSplitTarget else {
            errorMessage = "Pick someone to split with."
            return false
        }

        if !isManual {
            // The template's split option is left as-is — the runtime choice
            // here is one-shot, not a setting. Same for who's on it: a template
            // caches one friend, so a group or a multi-person split only links
            // the merchant, leaving the template's own friend untouched.
            // Only a Splitwise friend can be cached here: a template's
            // Only a single-person split is cached: a whole-ledger split has
            // no one person to remember, so it links the merchant without
            // touching the template's own target — same as a Splitwise group
            // used to.
            let cachedTarget = target.soleParticipant.map { participant in
                WalletTransactionConfig.CachedSplitTarget(
                    zoneName: target.zoneName,
                    participantID: participant.id,
                    firstName: participant.firstName,
                    fullName: participant.fullName
                )
            } ?? config.templates[finalTemplateName]?.splitTarget
            if let cachedTarget {
                configChanged = config.recordSplitMerchantLink(
                    merchant: merchant,
                    payeeName: finalPayeeName,
                    templateName: finalTemplateName,
                    target: cachedTarget
                )
            } else {
                configChanged = config.linkMerchantIfChanged(
                    merchant: merchant,
                    payeeName: finalPayeeName,
                    templateName: finalTemplateName
                )
            }
        }

        if configChanged {
            do {
                try WalletTransactionConfigStore.save(config)
            } catch {
                logger.error("failed to save config: \(String(describing: error), privacy: .public)")
            }
        }

        let choice = resolvedSplitAction
        guard choice != .never else {
            TransactionDraftGuard.complete(draft.id)
            return true
        }

        let allocation: SplitAllocation
        switch resolveAllocation(for: choice, amount: amount) {
        case .valid(let resolved): allocation = resolved
        case .invalid(let message):
            errorMessage = message
            return false
        }

        do {
            _ = try await SplitExpenseService.addExpense(
                amount: amount,
                description: finalDescription,
                target: target,
                allocation: allocation,
                merchant: isManual ? nil : merchant
            )
            TransactionDraftGuard.complete(draft.id)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
