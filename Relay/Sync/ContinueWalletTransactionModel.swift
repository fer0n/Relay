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

private let logger = Logger(subsystem: Const.loggerSubsystem, category: "ContinueWalletTransactionModel")

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

    /// True when this manual entry was seeded from a history entry — the
    /// "Re-add" action — rather than started blank. Only affects presentation
    /// (the amount field doesn't grab focus when there's already an amount to
    /// review); everything the prefill actually set lives in the fields below.
    let isPrefilled: Bool

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

    /// Payee name. For a YNAB draft this is the YNAB payee; for a Splitwise
    /// draft it's the merchant's clean name (stored as the merchant→template
    /// `payeeName` and used as the auto-match rule name). A shortcut-started
    /// Splitwise draft leaves it blank for an unknown merchant so its
    /// placeholder (the raw merchant) shows, falling back to that merchant
    /// via `splitwisePayeeName`.
    var payeeText = ""
    /// The Splitwise expense description, shown below the Payee field on a
    /// shortcut-started Splitwise draft. Blank means "use the payee name" —
    /// its placeholder mirrors `splitwisePayeeName`. Unused for YNAB drafts;
    /// a manual Splitwise entry keeps its single field bound to `payeeText`.
    var descriptionText = ""
    /// The YNAB memo, shown only in `.ynab` mode (YNAB, plus an optional
    /// Splitwise split — the "Both" option on a manual entry). Optional:
    /// blank means no memo. When the transaction is also split, it's
    /// appended to the Splitwise description too — see `splitDescription`.
    /// Unused in `.splitwise` mode, which has its own Description field.
    var memoText = ""
    /// Raw amount text — only used for a manual entry (isManual); a
    /// shortcut-started draft's amount comes fixed from the payload.
    var amountText = ""
    /// Selected mode for a manual entry (isManual) — switchable via the
    /// nav-bar menu; ignored otherwise (mode comes from the payload).
    var manualMode: Mode = .ynab
    var templateChoice: String?
    var availableTemplates: [String] = []
    /// Template name → its auto-match rules' distinct payee names, kept
    /// alongside `availableTemplates` (same load points) so the payee
    /// field's custom keyboard toolbar has suggestions ready without
    /// re-reading WalletTransactionConfigStore on every keystroke.
    private var templatePayeeNames: [String: [String]] = [:]

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

    init(draft: TransactionDraft, isManual: Bool = false, prefill: TransactionHistoryEntry? = nil, isAuthenticatedOverride: Bool? = nil) {
        self.draft = draft
        self.isManual = isManual
        self.isPrefilled = prefill != nil
        self.isAuthenticatedOverride = isAuthenticatedOverride
        defaultFriend = SplitwiseDefaultFriendStore.load()

        // A manual entry has no shortcut-supplied merchant/amount to resolve
        // against config — it starts blank on the last-used mode, with the
        // template list and default split friend ready for either mode.
        // Unless `prefill` is set (the "Re-add" action on a history entry),
        // in which case every field below is seeded from that entry instead
        // of the remembered last-used state.
        if isManual {
            let startMode = prefill.map { $0.service == .splitwise ? Mode.splitwise : Mode.ynab }
                ?? Self.resolveManualMode(ynabAuthenticated: ynabAuth.isAuthenticated, splitwiseAuthenticated: splitwiseAuth.isAuthenticated)
            manualMode = startMode
            let config = WalletTransactionConfigStore.load()
            availableTemplates = Array(config.templates.keys)
            templatePayeeNames = Self.payeeNamesByTemplate(config)
            if let defaultFriend {
                selectedFriendId = defaultFriend.id
            }
            if let prefill {
                applyPrefill(prefill, config: config)
            } else {
                selectedAccountId = Self.loadLastManualAccountId()
                splitwiseRuntimeChoice = Self.loadLastSplitChoice() ?? (startMode == .splitwise ? .always : .never)
                // A remembered template (more specific than a bare split
                // choice) re-applies its own category/split/friend on top of
                // the above, same as if the user had just picked it from the
                // row.
                if let lastTemplate = Self.loadLastManualTemplate(), availableTemplates.contains(lastTemplate) {
                    templateChoice = lastTemplate
                    applyTemplate(lastTemplate)
                }
            }
            return
        }

        // Resolved synchronously (local disk reads only) so the form's
        // defaults are in place on the very first render — no need to wait
        // on a `.task` for this part.
        switch draft.payload {
        case .ynabWallet(let merchant, _, let card):
            let config = WalletTransactionConfigStore.load()
            availableTemplates = Array(config.templates.keys)
            templatePayeeNames = Self.payeeNamesByTemplate(config)

            var resolvedTemplateFriend: (id: Int, firstName: String, fullName: String)?
            if let info = config.resolvedMerchantInfo(for: merchant) {
                templateChoice = info.templateName
                payeeText = info.payeeName
                let template = config.templates[info.templateName]
                selectedCategoryId = template?.categoryId
                // Drafts follow the merchant template's own split setting only
                // — never the global last-used choice, which would let the
                // last manual entry's pick spill into this draft.
                splitwiseRuntimeChoice = (template?.splitwiseOption ?? .never).splitRuntimeChoice
                resolvedTemplateFriend = template?.splitwiseFriend
            } else {
                payeeText = merchant
                // Unrecognized merchant — no template to carry a split default
                // from, so leave this unset rather than silently landing on
                // "don't split" (or an unrelated global last-used choice).
                // canSubmit's nil check then forces an explicit pick before
                // the transaction can go through, instead of letting an
                // unreviewed draft submit as soon as the account resolves.
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
            templatePayeeNames = Self.payeeNamesByTemplate(config)

            if let info = config.resolvedMerchantInfo(for: merchant) {
                templateChoice = info.templateName
                payeeText = info.payeeName
                let template = config.templates[info.templateName]
                // Drafts follow the merchant template's own split setting only
                // — never the global last-used choice, which would let the
                // last manual entry's pick spill into this draft.
                splitwiseRuntimeChoice = (template?.splitwiseOption ?? .never).splitRuntimeChoice
                if let friend = template?.splitwiseFriend {
                    templateHasFriend = true
                    templateFriend = SplitwiseFriendEntity(templateFriend: friend)
                    selectedFriendId = friend.id
                }
            } else {
                // Unknown merchant: leave the Payee field blank so its
                // placeholder (the raw merchant) shows; splitwisePayeeName
                // falls back to that merchant when it's left untouched.
                // No template to carry a split default from either, so leave
                // this unset rather than silently landing on "always split"
                // (or an unrelated global last-used choice) — canSubmit's
                // nil check forces an explicit pick before submitting.
                payeeText = ""
                splitwiseRuntimeChoice = nil
            }
        }
    }

    /// Seeds every field from a previously-created transaction/expense —
    /// backs the "Re-add" action on ContentView's recent-transactions list,
    /// which opens this sheet pre-filled instead of resubmitting silently,
    /// so the user can review or tweak it (a different amount, account,
    /// category, ...) before it's actually created again.
    private func applyPrefill(_ entry: TransactionHistoryEntry, config: WalletTransactionConfig) {
        switch entry.payload {
        case .ynabTransaction(let transaction):
            amountText = (abs(Double(transaction.amount)) / Const.milliunitsPerUnit).asMoneyString
            payeeText = transaction.payeeName
            // Left editable (accountResolved stays false, the AccountPickerRow's
            // default) rather than shown as a static label, unlike a
            // shortcut-resolved card mapping — a re-add should be reviewable.
            selectedAccountId = transaction.accountId
            selectedCategoryId = transaction.categoryId
            memoText = transaction.memo ?? ""
        case .splitwiseExpense(let expense):
            amountText = (Double(expense.costCents) / Const.centsPerUnit).asMoneyString
            payeeText = expense.description
        }

        // The history entry stores the transaction, not the template it came
        // from, so the template is worked backwards out of the config (see
        // templateName(forPayeeName:merchant:)). Assigned directly rather
        // than through applyTemplate(): the fields a template would push —
        // category, split option, friend — are already being seeded from the
        // entry itself just above/below, and are what a re-add should
        // reproduce. `.onChange(of: model.templateChoice)` in the view
        // doesn't fire for a value set here in init, so it won't overwrite
        // them either.
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
        switch mode {
        case .ynab:
            if payeeText.trimmingCharacters(in: .whitespaces).isEmpty { return false }
            if selectedAccountId == nil { return false }
            // Unlike Splitwise (which can auto-create a template from the
            // payee name on submit), YNAB requires an explicit template and
            // category up front — no silent auto-create/uncategorized path.
            if templateChoice == nil { return false }
            if selectedCategoryId == nil { return false }
            if splitwiseAuth.isAuthenticated, splitwiseRuntimeChoice == nil { return false }
            if resolvedSplitwiseAction != .never, selectedFriendId == nil && defaultFriend == nil { return false }
            if resolvedSplitwiseAction == .manual, Double(ownShareText) == nil { return false }
        case .splitwise:
            // A shortcut draft's description falls back to the merchant, so a
            // blank Payee/Description is fine; a manual entry has no merchant
            // and must supply one (its single field binds to payeeText).
            if splitwiseDescription.isEmpty { return false }
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

    /// The YNAB payee — the trimmed Payee field. Only meaningful in `.ynab`
    /// mode; the Splitwise side has `splitwisePayeeName`, which falls back to
    /// the merchant.
    var ynabPayeeName: String {
        payeeText.trimmingCharacters(in: .whitespaces)
    }

    /// The transaction's memo, or nil when the field was left blank (YNAB
    /// treats a missing memo and an empty one the same, so send nothing).
    var ynabMemo: String? {
        let trimmed = memoText.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The description for the Splitwise half of a `.ynab`-mode transaction:
    /// the payee on its own, or "<Payee>: <memo>" once a memo is typed, so
    /// the expense carries the same note as the YNAB memo rather than just
    /// the bare payee name.
    var splitDescription: String {
        guard let ynabMemo else { return ynabPayeeName }
        return "\(ynabPayeeName): \(ynabMemo)"
    }

    /// The payee name a Splitwise expense stores for its merchant — the typed
    /// Payee field, or the raw merchant when the field is left on its
    /// placeholder. For a manual entry (no merchant) this is just the typed
    /// text, which the single field binds to `payeeText`.
    var splitwisePayeeName: String {
        let typed = payeeText.trimmingCharacters(in: .whitespaces)
        return typed.isEmpty ? draft.merchant : typed
    }

    /// The Splitwise expense description — the typed Description field, or the
    /// effective payee name when the field is left on its placeholder. Also
    /// the value the Description field shows as its (grayed) placeholder.
    var splitwiseDescription: String {
        let typed = descriptionText.trimmingCharacters(in: .whitespaces)
        return typed.isEmpty ? splitwisePayeeName : typed
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
    private static func loadLastManualMode() -> Mode? {
        UserDefaults.standard.string(forKey: lastManualModeKey).flatMap(Mode.init(rawValue:))
    }

    /// Picks the mode a fresh manual entry opens on. The stored last-used
    /// mode only applies when both services are connected (it's a real
    /// choice there); with just one service connected, that one always wins
    /// regardless of what was last saved — otherwise a user who has only
    /// ever connected Splitwise (or disconnected YNAB after saving `.ynab`)
    /// would land on a "Connect YNAB" dead end despite Splitwise being
    /// fully usable. With neither connected, `.ynab` is an arbitrary
    /// fallback since some auth gate has to show.
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

    /// Explicit setter (bound in the view instead of the plain property) so
    /// a manual entry's account choice is remembered for next time. No-op
    /// for shortcut-started drafts, where the account instead comes from
    /// WalletTransactionConfigStore's per-card mapping.
    func setSelectedAccountId(_ id: String?) {
        selectedAccountId = id
        guard isManual else { return }
        Self.saveLastManualAccountId(id)
    }

    /// Explicit setter (bound in the view instead of the plain property) so
    /// a manual entry's split choice is remembered as the global "last used"
    /// default for the next manual entry (unlike the account/template
    /// equivalents below, this is remembered even without a template). Drafts
    /// deliberately don't participate: they neither seed from nor write to
    /// this value, so a draft always reflects its own merchant template's
    /// setting rather than whatever the last manual entry happened to pick
    /// (and vice versa — a draft's pick never spills back into manual).
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

    /// Re-applies the fields a chosen template controls — category (YNAB
    /// only), the split option, and the cached friend — or resets to
    /// per-mode defaults when the selection is cleared ("Create New"). The
    /// only mode-specific bits are that YNAB owns the category and that a
    /// from-scratch entry defaults to splitting every time on Splitwise but
    /// never on YNAB — both are only fallbacks for when there's no
    /// remembered global split choice yet (loadLastSplitChoice), which
    /// otherwise wins over the template's own saved splitwiseOption. Also
    /// persists the choice for a manual entry so the next one reopens on
    /// the same template (see loadLastManualTemplate).
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
                // Manual entries keep the global last-used choice as their
                // convenience default (per-mode fallback when none is saved).
                if name == nil {
                    splitwiseRuntimeChoice = Self.loadLastSplitChoice() ?? (mode == .splitwise ? .always : .never)
                } else {
                    splitwiseRuntimeChoice = Self.loadLastSplitChoice() ?? (template?.splitwiseOption ?? .never).splitRuntimeChoice
                }
            } else {
                // Drafts never read the global last-used choice (that's the
                // "new transaction default spilling into drafts"): the split
                // follows the picked template's own option, or stays unset —
                // forcing an explicit pick — when there's no template.
                splitwiseRuntimeChoice = name == nil ? nil : (template?.splitwiseOption ?? .never).splitRuntimeChoice
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
        templatePayeeNames = Self.payeeNamesByTemplate(config)
        templateChoice = name
        applyTemplate(name)
    }

    private static func payeeNamesByTemplate(_ config: WalletTransactionConfig) -> [String: [String]] {
        config.templates.mapValues { Array(Set($0.autoMatch.map(\.payeeName))).sorted() }
    }

    /// Payee-name suggestions for the payee field's custom keyboard toolbar
    /// — the selected template's own auto-match payee names first (so they
    /// win the limited slots), followed by every other template's (deduped
    /// against the selected one's), filtered down to what's already been
    /// typed (like a normal autocomplete) so there's always something to
    /// pick from instead of retyping an already-known payee.
    var suggestedPayeeNames: [String] {
        let ownNames = templateChoice.flatMap { templatePayeeNames[$0] } ?? []
        let otherNames = Array(Set(templatePayeeNames.values.flatMap { $0 }).subtracting(ownNames)).sorted()
        let names = ownNames + otherNames
        let typed = payeeText.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return names }
        return names.filter { $0.localizedStandardContains(typed) }
    }

    /// Whether the payee field's typed text is worth offering a quick
    /// "Add to <template>" action for — few enough existing matches that
    /// this looks like a new/rare payee rather than one already covered by
    /// an auto-match rule. Also false once a rule for this exact text
    /// already exists, since linking again would just add a duplicate.
    var showsLinkToTemplate: Bool {
        let typed = payeeText.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return false }
        let names = suggestedPayeeNames
        guard !names.contains(where: { $0.caseInsensitiveCompare(typed) == .orderedSame }) else { return false }
        return names.count <= 2
    }

    /// The template `linkPayeeToTemplate` would attach its rule to — the
    /// selected template, or (matching that method's own fallback) a new
    /// one named after the payee when none is selected yet. Exposed so the
    /// "Add to <name>" action's label can name the actual target.
    var linkToTemplateName: String {
        templateChoice ?? payeeText.trimmingCharacters(in: .whitespaces)
    }

    /// Adds an auto-match rule (pattern == payee name, both the current
    /// typed text) to the selected template — or a new template named
    /// after the payee, same as the "create a new template" path submit()
    /// already takes when none is selected — so this exact payee resolves
    /// automatically next time instead of needing to be retyped. Unlike
    /// that submit-time path (which only maps the shortcut-supplied
    /// merchant string), this works for manual entries too, which have no
    /// merchant string to map.
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
        templatePayeeNames = Self.payeeNamesByTemplate(config)
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
        // Show the cache instantly; skip the live fetch while it's fresh so
        // re-entering this flow doesn't re-hit YNAB (200 req/hr).
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

        let trimmedPayee = ynabPayeeName
        guard !trimmedPayee.isEmpty else {
            errorMessage = "Payee name can't be empty."
            return false
        }
        let finalPayeeName = trimmedPayee
        let finalCategoryId = selectedCategoryId

        // Template is required to submit (canSubmit), so it's always set here
        // — persist an edited payee (or a template change) so it's corrected
        // automatically next time, matching the Splitwise flow. No-op when
        // nothing changed.
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

        // Shared by the YNAB write and the Splitwise split (when there is
        // one) so the two fold into a single combined history entry.
        let groupId = (action != .never && friend != nil) ? UUID() : nil

        async let ynabOutcome = PendingSync.createYNABTransaction(transaction, token: token, summary: "\(formattedAmount) at \(finalPayeeName)", groupId: groupId)
        // The split's description carries the memo too ("<Payee>: <memo>"),
        // unlike the YNAB side where payee and memo are separate fields.
        async let splitDialogFragment = createSplitIfNeeded(friend: friend, description: splitDescription, amount: amount, action: action, ownShare: ownShare, groupId: groupId)

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
        return await WalletAutomationDialog.splitDialogFragment(amount: amount, description: description, friend: friend, ownShare: ownShare, groupId: groupId).fragment
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

        // The expense description and the merchant's stored payee name are now
        // separate fields (the Payee field drives the mapping name; the
        // Description field is the expense text). Blank fields fall back per
        // splitwisePayeeName / splitwiseDescription.
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
            // No template picked for a shortcut-started draft — file it under
            // the default Splitwise template (created on demand) rather than
            // spawning a per-payee template, matching the intent's flow.
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
            // File the merchant under its template and cache the friend. The
            // (default) template's split option is left as-is — it stays
            // `.ask` so it keeps prompting; the one-shot runtime choice here
            // isn't a persistent setting. Re-links the merchant when the Payee
            // was edited, so the correction is applied automatically next time.
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
