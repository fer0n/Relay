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
    private let friendOverride: SplitwiseSplitTargetEntity?

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

    var splitwiseRuntimeChoice: SplitwiseSplitChoice? = .never
    var friends: [SplitwiseFriend] = []
    var groups: [SplitwiseGroup] = []
    /// Who the split is with: any number of friends, or one group. Empty means
    /// "whatever the app-wide default friend is" — see `resolvedSplitTarget`.
    var participantSelection = SplitwiseSplitSelection.empty
    var participantSearchText = ""
    var isLoadingFriends = false
    var ownShareText = ""
    /// `.shares` only — relative weights, reset to an even 1 each per form
    /// (like SplitwiseExpenseDetailView's shares mode), since they describe
    /// this one transaction rather than a setting. Keyed by participant user
    /// id; a missing entry is an unedited `1`.
    var ownWeightText = "1"
    var participantWeightTexts: [Int: String] = [:]

    /// The single-friend view of `participantSelection`, kept so the surfaces
    /// and tests that only ever deal in one friend don't have to know about the
    /// multi-participant shape. Setting it replaces the whole selection.
    var selectedFriendId: Int? {
        get { participantSelection.participantIds.first }
        set { participantSelection = newValue.map { .friend($0) } ?? .empty }
    }

    /// A template's own friend beats the app-wide default. It seeds the picker
    /// rather than locking it, so more people can still be added to this one
    /// transaction without editing the template.
    var templateHasFriend = false
    var templateFriend: SplitwiseSplitTargetEntity?

    /// Seeds the picker from a target picked in Shortcuts, which can be a group
    /// as well as a friend — a template and a draft's pending split context
    /// both store whichever was chosen there. A group is expanded to its
    /// membership, falling back to the on-disk cache when the live list isn't
    /// loaded yet; `fillGroupMembersIfNeeded` catches the case where neither
    /// had it.
    private static func selection(for entity: SplitwiseSplitTargetEntity, groups: [SplitwiseGroup]) -> SplitwiseSplitSelection {
        guard entity.kind == .group else { return .friend(entity.splitwiseId) }
        let groupId = entity.splitwiseId
        let group = groups.first { $0.id == groupId }
            ?? SplitwiseGroupCacheStore.load()?.first { $0.id == groupId }
        let memberIds = group?.others(excluding: SplitwiseCurrentUserStore.load()?.id).map(\.id) ?? []
        return .group(groupId, memberIds: memberIds)
    }

    /// The live list if it's loaded, otherwise the on-disk cache — a form can
    /// open, and submit, before `loadFriends()` has been anywhere near the
    /// network.
    private func cachedGroup(id: Int) -> SplitwiseGroup? {
        groups.first { $0.id == id } ?? SplitwiseGroupCacheStore.load()?.first { $0.id == id }
    }

    /// Fills in a picked group's members once the group list has loaded, for a
    /// selection seeded before it was there.
    private func fillGroupMembersIfNeeded() {
        guard let groupId = participantSelection.groupId,
              participantSelection.participantIds.isEmpty,
              let group = groups.first(where: { $0.id == groupId }) else { return }
        participantSelection.setGroup(
            groupId,
            memberIds: group.others(excluding: SplitwiseCurrentUserStore.load()?.id).map(\.id)
        )
    }

    // MARK: Init

    init(draft: TransactionDraft, isManual: Bool = false, prefill: TransactionHistoryEntry? = nil, isAuthenticatedOverride: Bool? = nil, friendOverride: SplitwiseSplitTargetEntity? = nil) {
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
                participantSelection = Self.selection(for: friendOverride, groups: [])
            } else if let defaultFriend {
                participantSelection = Self.selection(for: SplitwiseSplitTargetEntity(defaultFriend: defaultFriend), groups: [])
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

            var resolvedTemplateFriend: WalletTransactionConfig.CachedSplitTarget?
            if let info = config.resolvedMerchantInfo(for: merchant) {
                templateChoice = info.templateName
                payeeText = info.payeeName
                let template = config.templates[info.templateName]
                selectedCategoryId = template?.categoryId
                // Never the global last-used choice, which would let the last
                // manual entry's pick spill into this draft.
                splitwiseRuntimeChoice = (template?.splitwiseOption ?? .never).splitRuntimeChoice.map(SplitwiseSplitChoice.init)
                resolvedTemplateFriend = template?.splitwiseTarget
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
                let entity = SplitwiseSplitTargetEntity(cachedTarget: resolvedTemplateFriend)
                templateFriend = entity
                participantSelection = Self.selection(for: entity, groups: [])
            } else if let defaultFriend {
                participantSelection = Self.selection(for: SplitwiseSplitTargetEntity(defaultFriend: defaultFriend), groups: [])
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
                splitwiseRuntimeChoice = (template?.splitwiseOption ?? .never).splitRuntimeChoice.map(SplitwiseSplitChoice.init)
                if let friend = template?.splitwiseTarget {
                    templateHasFriend = true
                    let entity = SplitwiseSplitTargetEntity(cachedTarget: friend)
                    templateFriend = entity
                    participantSelection = Self.selection(for: entity, groups: [])
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
        participantSelection = SplitwiseSplitSelection(
            participantIds: splitExpense.others.map(\.userId),
            groupId: splitExpense.groupId == 0 ? nil : splitExpense.groupId
        )
        // An even split reproduces as "Split Equally" so re-adding it follows a
        // changed amount, rather than freezing yesterday's cents into a manual
        // share.
        let evenSplit = SplitwiseSplitAllocation.equal.owedCents(
            totalCents: splitExpense.costCents,
            participantCount: splitExpense.others.count
        )
        if splitExpense.payerOwedCents == evenSplit?.first {
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

    var resolvedSplitwiseAction: SplitwiseSplitChoice {
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

    /// The amount a split is worked out against — the same value `submit()`
    /// books, so the share rows can't show numbers the write disagrees with.
    /// Nil while a typed amount is unparseable.
    var splitAmount: Double? {
        amountIsEditable ? manualAmount : draft.amount
    }

    /// Everyone the split is with, in the order their `.shares` rows appear.
    var splitParticipants: [SplitwiseSplitParticipant] {
        resolvedSplitTarget?.participants ?? []
    }

    /// A `.shares` weight, defaulting to an even 1 for anyone not edited yet.
    func weightText(for participantId: Int) -> String {
        participantWeightTexts[participantId] ?? "1"
    }

    func setWeightText(_ text: String, for participantId: Int) {
        participantWeightTexts[participantId] = text
    }

    /// The `.shares` weights as `[yours, theirs…]`, in `splitParticipants`
    /// order. Nil if any of them is unparseable.
    private var shareWeights: [Double]? {
        guard let mine = SplitwiseShareMath.cents(ownWeightText) else { return nil }
        var weights = [Double(mine)]
        for participant in splitParticipants {
            guard let weight = SplitwiseShareMath.cents(weightText(for: participant.id)) else { return nil }
            weights.append(Double(weight))
        }
        return weights
    }

    /// The chosen split as an allocation, or nil while its own inputs can't be
    /// read — an unparseable own share, a bad weight.
    private var currentAllocation: SplitwiseSplitAllocation? {
        switch resolvedSplitwiseAction {
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
            totalCents: SplitwiseShareMath.cents(fromAmount: amount),
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
        splitAmount.flatMap { splitOwedCents(amount: $0) }.map { SplitwiseShareMath.text(fromCents: $0[0]) }
    }

    func shareAmountText(for participantId: Int) -> String? {
        guard let index = splitParticipants.firstIndex(where: { $0.id == participantId }),
              let amount = splitAmount,
              let owed = splitOwedCents(amount: amount) else { return nil }
        return SplitwiseShareMath.text(fromCents: owed[index + 1])
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
            if resolvedSplitwiseAction != .never, resolvedSplitTarget == nil { return false }
            if !splitInputsValid { return false }
        case .splitwise:
            if splitwiseDescription.isEmpty { return false }
            if resolvedSplitTarget == nil { return false }
            if splitwiseRuntimeChoice == nil { return false }
            if !splitInputsValid { return false }
        }
        return true
    }

    /// Whether the chosen split mode's own inputs are usable — a typed own
    /// share for `.manual`, weights that add up to something for `.shares`.
    private var splitInputsValid: Bool {
        switch resolvedSplitwiseAction {
        case .always, .never:
            return true
        case .manual:
            return Double(ownShareText) != nil
        case .shares:
            guard let amount = splitAmount else { return false }
            return splitOwedCents(amount: amount) != nil
        }
    }

    var friendNoneLabel: String {
        defaultFriend.map { "Default (\($0.firstName))" } ?? "None"
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
    var resolvedSplitTarget: SplitwiseSplitTarget? {
        let group = participantSelection.groupId.flatMap { cachedGroup(id: $0) }
        // A picked group that isn't in the cache would post the expense into a
        // group we can't name or check the membership of, so it isn't offered
        // as a target at all.
        if participantSelection.groupId != nil, group == nil { return nil }

        guard !participantSelection.participantIds.isEmpty else {
            guard group == nil else { return nil }
            return defaultTarget
        }
        let participants = participantSelection.participantIds.compactMap(resolveParticipant)
        guard !participants.isEmpty else { return nil }
        return SplitwiseSplitTarget(participants: participants, groupId: group?.id, groupName: group?.name)
    }

    /// What an untouched picker books against: the app-wide default, which can
    /// be a group — in which case it resolves to that group's membership, the
    /// same as picking it would.
    private var defaultTarget: SplitwiseSplitTarget? {
        guard let defaultFriend else { return nil }
        guard defaultFriend.isGroup else {
            return SplitwiseSplitTarget(
                participants: [SplitwiseSplitParticipant(id: defaultFriend.id, firstName: defaultFriend.firstName, fullName: defaultFriend.fullName)]
            )
        }
        guard let cached = cachedGroup(id: defaultFriend.id) else { return nil }
        let members = cached.others(excluding: SplitwiseCurrentUserStore.load()?.id)
            .map(SplitwiseSplitParticipant.init(member:))
        guard !members.isEmpty else { return nil }
        return SplitwiseSplitTarget(participants: members, groupId: cached.id, groupName: cached.name)
    }

    /// The friend list can still be empty (offline, cache not warmed), but a
    /// pick that came from the override, a template or the default already
    /// carries names.
    private func resolveParticipant(_ id: Int) -> SplitwiseSplitParticipant? {
        if let match = friends.first(where: { $0.id == id }) {
            return SplitwiseSplitParticipant(friend: match)
        }
        if let member = groups.lazy.flatMap(\.memberList).first(where: { $0.id == id }) {
            return SplitwiseSplitParticipant(member: member)
        }
        if let friendOverride, friendOverride.splitwiseId == id { return SplitwiseSplitParticipant(entity: friendOverride) }
        if let templateFriend, templateFriend.splitwiseId == id { return SplitwiseSplitParticipant(entity: templateFriend) }
        if let defaultFriend, defaultFriend.id == id {
            return SplitwiseSplitParticipant(id: id, firstName: defaultFriend.firstName, fullName: defaultFriend.fullName)
        }
        return nil
    }

    /// The single friend a split books against, when that's all it is — nil for
    /// a group or a multi-person split. Kept for the config surfaces that store
    /// exactly one friend.
    var resolvedSplitFriend: SplitwiseSplitTargetEntity? {
        resolvedSplitTarget?.soleFriend.map {
            SplitwiseSplitTargetEntity(splitwiseId: $0.id, firstName: $0.firstName, fullName: $0.fullName)
        }
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
    func setSplitwiseRuntimeChoice(_ choice: SplitwiseSplitChoice?) {
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
    private static func loadLastSplitChoice() -> SplitwiseSplitChoice? {
        UserDefaults.standard.string(forKey: lastSplitChoiceKey).flatMap(SplitwiseSplitChoice.init(rawValue:))
    }
    private static func saveLastSplitChoice(_ choice: SplitwiseSplitChoice?) {
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
                    splitwiseRuntimeChoice = Self.loadLastSplitChoice()
                        ?? (template?.splitwiseOption ?? .never).splitRuntimeChoice.map(SplitwiseSplitChoice.init)
                }
            } else {
                // Drafts never read the global last-used choice: follow the
                // picked template's option, or stay unset to force a pick.
                splitwiseRuntimeChoice = name == nil
                    ? nil
                    : (template?.splitwiseOption ?? .never).splitRuntimeChoice.map(SplitwiseSplitChoice.init)
            }
            if let friendOverride {
                templateHasFriend = false
                templateFriend = nil
                participantSelection = Self.selection(for: friendOverride, groups: groups)
            } else if let friend = template?.splitwiseTarget {
                templateHasFriend = true
                let entity = SplitwiseSplitTargetEntity(cachedTarget: friend)
                templateFriend = entity
                participantSelection = Self.selection(for: entity, groups: groups)
            } else {
                templateHasFriend = false
                templateFriend = nil
                participantSelection = SplitwiseDefaultFriendStore.load()
                    .map { Self.selection(for: SplitwiseSplitTargetEntity(defaultFriend: $0), groups: groups) } ?? .empty
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

    /// Friends and groups together — the participant picker offers both, so a
    /// half-loaded list would silently hide one kind of target.
    private func loadFriends() async {
        guard let token = SplitwiseAuthService.currentAccessToken else { return }
        if let cached = SplitwiseFriendCacheStore.load() {
            friends = SplitwiseFriendUsageStore.sorted(cached)
        }
        if let cached = SplitwiseGroupCacheStore.load() {
            groups = cached
            fillGroupMembersIfNeeded()
        }
        // Groups list their whole membership, the signed-in user included, and
        // `resolvedSplitTarget` needs their id to leave them out of the shares
        // it previews. The write resolves it either way — this just keeps the
        // numbers on screen from being the ones it corrects.
        if SplitwiseCurrentUserStore.load() == nil,
           let user = try? await SplitwiseService.fetchCurrentUser(token: token) {
            try? SplitwiseCurrentUserStore.save(user)
        }
        let friendsAreStale = SplitwiseFriendCacheStore.isStale
        let groupsAreStale = SplitwiseGroupCacheStore.isStale
        guard friendsAreStale || groupsAreStale else { return }
        isLoadingFriends = friends.isEmpty && groups.isEmpty
        defer { isLoadingFriends = false }
        async let fetchedFriends: [SplitwiseFriend]? = friendsAreStale
            ? try? await SplitwiseFriendCacheStore.fetch(token: token)
            : nil
        async let fetchedGroups: [SplitwiseGroup]? = groupsAreStale
            ? try? await SplitwiseGroupCacheStore.fetch(token: token)
            : nil
        if let loaded = await fetchedFriends {
            friends = SplitwiseFriendUsageStore.sorted(loaded)
        } else if friendsAreStale {
            logger.error("failed to load friends")
        }
        if let loaded = await fetchedGroups {
            groups = loaded
            fillGroupMembersIfNeeded()
        } else if groupsAreStale {
            logger.error("failed to load groups")
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

        let choice = resolvedSplitwiseAction
        let action = choice.submitOption

        // `let`, not `var`: captured by the `async let` below, where a mutable
        // var trips Swift 6 strict concurrency checking.
        let allocation: SplitwiseSplitAllocation
        switch resolveAllocation(for: choice, amount: amount) {
        case .valid(let resolved): allocation = resolved
        case .invalid(let message):
            errorMessage = message
            return false
        }

        let target: SplitwiseSplitTarget?
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
        case valid(SplitwiseSplitAllocation)
        case invalid(String)
    }

    /// How the chosen mode divides the cost: evenly, by the typed own share for
    /// `.manual`, or by the weights for `.shares`.
    private func resolveAllocation(for choice: SplitwiseSplitChoice, amount: Double) -> AllocationResolution {
        switch choice {
        case .always, .never:
            return .valid(.equal)
        case .manual:
            switch SplitwiseExpenseHelper.parseOwnShare(ownShareText, amount: amount) {
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
        target: SplitwiseSplitTarget?,
        description: String,
        amount: Double,
        action: SplitwiseSplitOption,
        allocation: SplitwiseSplitAllocation,
        groupId: UUID?,
        merchant: String?
    ) async -> String? {
        guard action != .never, let target else { return nil }
        return await WalletAutomationDialog.splitDialogFragment(amount: amount, description: description, target: target, allocation: allocation, groupId: groupId, merchant: merchant).fragment
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

        guard let target = resolvedSplitTarget else {
            errorMessage = "Pick someone to split with."
            return false
        }

        if !isManual {
            // The template's split option is left as-is — the runtime choice
            // here is one-shot, not a setting. Same for who's on it: a template
            // caches one friend, so a group or a multi-person split only links
            // the merchant, leaving the template's own friend untouched.
            let cachedTarget = target.soleFriend.map {
                WalletTransactionConfig.CachedSplitTarget(id: $0.id, firstName: $0.firstName, fullName: $0.fullName)
            } ?? config.templates[finalTemplateName]?.splitwiseTarget
            if let cachedTarget {
                configChanged = config.recordSplitwiseMerchantLink(
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

        let choice = resolvedSplitwiseAction
        guard choice != .never else {
            TransactionDraftGuard.complete(draft.id)
            return true
        }

        let allocation: SplitwiseSplitAllocation
        switch resolveAllocation(for: choice, amount: amount) {
        case .valid(let resolved): allocation = resolved
        case .invalid(let message):
            errorMessage = message
            return false
        }

        do {
            _ = try await SplitwiseExpenseHelper.addExpense(
                amount: amount,
                description: finalDescription,
                target: target,
                allocation: allocation,
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
