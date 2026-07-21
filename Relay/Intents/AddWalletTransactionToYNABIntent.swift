//
//  AddWalletTransactionToYNABIntent.swift
//  Relay
//
//  Siri/Shortcuts equivalent of the "Transaction → YNAB" Shortcut being
//  replaced (see docs/project-goals.md). Meant to be wired up as the action
//  of a Shortcuts "Transaction" Personal Automation, receiving the Wallet
//  transaction's Merchant/Amount/Card magic variables directly — no more
//  DataJar/Jayson/YNAB Toolkit dependency.
//
//  Splitwise mirrors the original: "Use Splitwise?" (always/manual/ask/
//  never — see SplitwiseTemplateOption) is asked once per new template
//  (right after choosing its category) and the choice is remembered on the
//  template, same as category/account. "Ask" keeps prompting live on every
//  future transaction for that merchant via `splitwiseRuntimeChoice`,
//  mirroring the original's Ja/Manuell/Nein menu.
//
//  The Splitwise friend to split with is a separate question from whether
//  to split at all: if the resolved template already has one set (e.g.
//  configured in Templates, or shared with AddWalletTransactionToSplitwise
//  Intent's template of the same name), that's used directly; otherwise
//  this falls back to `splitwiseFriendFallback` (default friend or a live
//  ask) exactly as before templates could carry a friend.
//

import AppIntents
import os

private let logger = Logger(subsystem: "com.octabits.relay", category: "WalletTransaction")

nonisolated struct AddWalletTransactionToYNABIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Wallet Transaction to YNAB"
    static let description = IntentDescription(
        "Adds a YNAB transaction from a Wallet transaction, remembering payee/category/account choices for next time."
    )

    @Parameter(title: "Merchant")
    var merchant: String

    @Parameter(title: "Amount")
    var amount: Double

    @Parameter(title: "Card")
    var card: String

    @Parameter(title: "Template", optionsProvider: TemplateOptionsProvider())
    var templateChoice: String?

    @Parameter(title: "Template Name")
    var newTemplateName: String?

    @Parameter(title: "Payee")
    var payeeOverride: String?

    @Parameter(title: "Auto-Match Pattern")
    var autoMatchPattern: String?

    @Parameter(title: "Category")
    var categoryOverride: YNABCategoryEntity?

    @Parameter(title: "Account")
    var accountOverride: YNABAccountEntity?

    @Parameter(title: "Split with Splitwise")
    var splitwiseOptionOverride: SplitwiseTemplateOption?

    @Parameter(title: "Split With")
    var splitwiseFriend: SplitwiseFriendEntity?

    /// What to do when `splitwiseFriend` is left unset: silently fall back
    /// to `SplitwiseDefaultFriendStore`'s app-configured default (the
    /// out-of-the-box behavior), or prompt live via requestDisambiguation.
    @Parameter(title: "If Split With Isn't Set", default: .defaultFriend)
    var splitwiseFriendFallback: SplitwiseFriendFallback

    @Parameter(title: "Your Share")
    var splitwiseOwnShare: Double?

    /// Only used when the resolved template's Splitwise option is "Ask
    /// Each Time" — the live per-transaction equivalent of the original's
    /// Ja/Manuell/Nein menu.
    @Parameter(title: "Split Transaction?")
    var splitwiseRuntimeChoice: SplitwiseSplitOption?

    /// See TransactionDraftGuard: if this run gets interrupted (a follow-up
    /// question dismissed/timed out, the process killed by a screen lock)
    /// before the transaction is actually created, a local notification
    /// nudges the user to go finish it — since there's no way to resume a
    /// suspended perform() call.
    @Parameter(title: "Ensure Completion", description: "If this run is interrupted before finishing, send a notification to continue it later.", default: true)
    var ensureCompletion: Bool

    // Parameters requested at runtime via `$param.requestValue(...)` MUST
    // appear here: on iOS 18+ requestValue throws a connection error for a
    // parameter that isn't in parameterSummary (FB14828592, confirmed still
    // present on iOS 26). That rules out hiding the free-text/number setup
    // fields (newTemplateName, payeeOverride, autoMatchPattern,
    // splitwiseOwnShare). The entity/enum setup fields (categoryOverride,
    // accountOverride, splitwiseOptionOverride) are instead resolved with
    // requestDisambiguation, which passes its candidate list inline and so
    // works while omitted here. `splitwiseFriend`/`splitwiseFriendFallback`
    // are listed even though the "default friend" path never actively
    // requests a value — kept visible so a specific automation can still
    // pick a friend by hand or opt into live asking. `card` is folded into
    // the main sentence since it's required. Shortcuts collapses the rest
    // under "Show More" rather than showing them inline.
    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$amount) at \(\.$merchant) with \(\.$card) to YNAB") {
            \.$templateChoice
            \.$newTemplateName
            \.$payeeOverride
            \.$autoMatchPattern
            \.$splitwiseFriend
            \.$splitwiseFriendFallback
            \.$splitwiseOwnShare
            \.$splitwiseRuntimeChoice
            \.$ensureCompletion
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        logger.log("perform() start — merchant=\(merchant, privacy: .public) amount=\(amount, privacy: .public) card=\(card, privacy: .public)")

        // The draft the safety-net reminder currently guards. Starts as the
        // .ynabWallet draft (the whole transaction is unfinished); once YNAB
        // is committed below it's swapped for a .splitwiseWallet draft (only
        // the optional split remains), and the catch handler always fails
        // whichever one is active.
        var activeDraftId = ensureCompletion
            ? TransactionDraftGuard.begin(.ynabWallet(merchant: merchant, amount: amount, card: card))
            : nil

        // Pushes the "still needs finishing" reminder back out — called
        // after every follow-up question below is answered, so a normal but
        // slow-to-answer run doesn't get a premature nudge mid-flow.
        func touchDraft() {
            if let activeDraftId {
                TransactionDraftGuard.touch(activeDraftId)
            }
        }

        do {
            await PendingOperationQueue.shared.flush()

            guard let token = await YNABAuthService.validAccessToken() else {
                logger.error("no YNAB access token in Keychain — not authenticated")
                throw YNABIntentError.notAuthenticated
            }
            logger.log("YNAB token present (len=\(token.count, privacy: .public))")

            var config = WalletTransactionConfigStore.load()
            var changed = false

            // Uses the async `requestValue` API (suspend perform() in place, await
            // the answer, resume) rather than the deprecated throwing form that
            // re-runs perform() from the top. In-place resolution is why these
            // parameters don't need to appear in `parameterSummary` (the throwing
            // form only binds collected values back for summary parameters, so a
            // hidden parameter would hang), and it also removes the duplicate-
            // transaction risk of a restart since perform() now runs exactly once.
            let payeeName: String
            let categoryId: String?
            let splitwiseOption: SplitwiseTemplateOption
            let templateFriend: (id: Int, firstName: String, fullName: String)?

            if let info = config.resolvedMerchantInfo(for: merchant) {
                logger.log("merchant resolved to payee=\(info.payeeName, privacy: .public) template=\(info.templateName, privacy: .public)")
                if config.merchants[merchant] == nil {
                    config.merchants[merchant] = info
                    changed = true
                }
                let template = config.templates[info.templateName]
                payeeName = info.payeeName
                categoryId = template?.categoryId
                splitwiseOption = template?.splitwiseOption ?? .never
                templateFriend = template?.splitwiseFriend
            } else {
                let resolvedTemplateChoice: String
                if let templateChoice {
                    resolvedTemplateChoice = templateChoice
                } else {
                    logger.log("no merchant match — requesting template choice")
                    let prompt = String(format: String(localized: "Which template for \"%@\"?"), merchant)
                    resolvedTemplateChoice = try await $templateChoice.requestValue(IntentDialog(stringLiteral: prompt))
                    touchDraft()
                }

                let templateName: String
                let existingTemplate: WalletTransactionConfig.Template?
                if resolvedTemplateChoice != createNewTemplateOption, let existing = config.templates[resolvedTemplateChoice] {
                    templateName = resolvedTemplateChoice
                    existingTemplate = existing
                } else {
                    let newName: String
                    if let newTemplateName {
                        newName = newTemplateName
                    } else {
                        logger.log("creating new template — requesting template name")
                        newName = try await $newTemplateName.requestValue(IntentDialog(stringLiteral: String(localized: "Template name?")))
                        touchDraft()
                    }
                    templateName = newName
                    existingTemplate = config.templates[newName]
                }

                let resolvedPayeeName: String
                if let payeeOverride {
                    resolvedPayeeName = payeeOverride
                } else {
                    logger.log("template=\(templateName, privacy: .public) — requesting payee name")
                    let prompt = String(format: String(localized: "Payee name for \"%@\"?"), merchant)
                    resolvedPayeeName = try await $payeeOverride.requestValue(IntentDialog(stringLiteral: prompt))
                    touchDraft()
                }

                let pattern: String
                if let autoMatchPattern {
                    pattern = autoMatchPattern
                } else {
                    logger.log("payeeName=\(resolvedPayeeName, privacy: .public) — requesting auto-match pattern")
                    let prompt = String(
                        format: String(localized: "Match other merchant names to %@ too? Enter text/regex, or leave blank to skip."),
                        resolvedPayeeName
                    )
                    pattern = try await $autoMatchPattern.requestValue(IntentDialog(stringLiteral: prompt))
                    touchDraft()
                }
                logger.log("autoMatchPattern=\"\(pattern, privacy: .public)\"")

                let resolvedCategoryId: String?
                if let existingTemplate {
                    resolvedCategoryId = existingTemplate.categoryId
                } else {
                    let category: YNABCategoryEntity
                    if let categoryOverride {
                        category = categoryOverride
                    } else {
                        logger.log("payeeName=\(resolvedPayeeName, privacy: .public) — requesting category")
                        // requestDisambiguation (not requestValue) so this param
                        // can stay out of parameterSummary — see the note there.
                        let categories = try await YNABCategoryEntity.defaultQuery.suggestedEntities()
                        category = try await $categoryOverride.requestDisambiguation(
                            among: categories,
                            dialog: IntentDialog(stringLiteral: String(format: String(localized: "Category for %@?"), templateName))
                        )
                        touchDraft()
                    }
                    resolvedCategoryId = category.id
                }

                let resolvedSplitwiseOption: SplitwiseTemplateOption
                if let existingTemplate {
                    resolvedSplitwiseOption = existingTemplate.splitwiseOption
                } else if SplitwiseAuthService.currentAccessToken == nil {
                    // Don't ask a YNAB-only user to configure a Splitwise
                    // setting for their new template.
                    resolvedSplitwiseOption = .never
                } else {
                    if let splitwiseOptionOverride {
                        resolvedSplitwiseOption = splitwiseOptionOverride
                    } else {
                        logger.log("categoryId=\(resolvedCategoryId ?? "nil", privacy: .public) — requesting Splitwise option")
                        resolvedSplitwiseOption = try await $splitwiseOptionOverride.requestDisambiguation(
                            among: [.ask, .always, .manual, .never],
                            dialog: IntentDialog(stringLiteral: String(format: String(localized: "Split %@ expenses with Splitwise?"), templateName))
                        )
                        touchDraft()
                    }
                }

                var template = existingTemplate ?? WalletTransactionConfig.Template(
                    categoryId: resolvedCategoryId,
                    splitwiseOption: resolvedSplitwiseOption
                )
                if !pattern.isEmpty {
                    template.autoMatch.append(.init(pattern: pattern, payeeName: resolvedPayeeName))
                }
                config.templates[templateName] = template
                config.merchants[merchant] = WalletTransactionConfig.MerchantInfo(payeeName: resolvedPayeeName, templateName: templateName)
                payeeName = resolvedPayeeName
                categoryId = resolvedCategoryId
                splitwiseOption = resolvedSplitwiseOption
                templateFriend = template.splitwiseFriend
                changed = true
            }

            let accountId: String
            if let existingAccountId = config.cards[card] {
                logger.log("card matched existing accountId=\(existingAccountId, privacy: .public)")
                accountId = existingAccountId
            } else {
                let account: YNABAccountEntity
                if let accountOverride {
                    account = accountOverride
                } else {
                    logger.log("no account match for card — requesting account")
                    // requestDisambiguation (not requestValue) so this param can
                    // stay out of parameterSummary — see the note there.
                    let accounts = try await YNABAccountEntity.defaultQuery.suggestedEntities()
                    account = try await $accountOverride.requestDisambiguation(
                        among: accounts,
                        dialog: IntentDialog(stringLiteral: String(format: String(localized: "YNAB account for card \"%@\"?"), card))
                    )
                    touchDraft()
                }
                logger.log("accountId=\(account.id, privacy: .public)")
                config.cards[card] = account.id
                accountId = account.id
                changed = true
            }

            // The YNAB-side mappings (payee/template/card) are fully resolved
            // by here; persist them before committing YNAB so an interrupted
            // split phase below can't lose them.
            if changed {
                do {
                    try WalletTransactionConfigStore.save(config)
                    logger.log("config saved")
                } catch {
                    logger.error("failed to save config: \(String(describing: error), privacy: .public)")
                }
            }

            // Commit YNAB now — it never depends on the split decision, so
            // there's no reason to hold it behind the Splitwise questions.
            // Once it's in, the .ynabWallet guard's job is done, and any
            // interruption of the (optional) split below leaves the YNAB
            // transaction complete rather than losing the whole run.
            let milliunits = -Int((amount * 1000).rounded()) // outflow: negative milliunits
            let transaction = YNABTransactionRequest(
                accountId: accountId,
                date: YNABService.todayDateString(),
                amount: milliunits,
                payeeName: payeeName,
                categoryId: categoryId,
                memo: nil,
                cleared: "uncleared",
                approved: true
            )
            let formattedAmount = amount.asMoneyString
            logger.log("creating YNAB transaction: accountId=\(accountId, privacy: .public) amountMilliunits=\(milliunits, privacy: .public) payee=\(payeeName, privacy: .public) categoryId=\(categoryId ?? "nil", privacy: .public)")
            let ynabOutcome = try await PendingSync.createYNABTransaction(transaction, token: token, summary: "\(formattedAmount) at \(payeeName)")
            var dialog = WalletAutomationDialog.handleYNABOutcome(ynabOutcome, formattedAmount: formattedAmount, payeeName: payeeName, categoryId: categoryId)
            logger.log("YNAB result: \(dialog, privacy: .public)")

            // A template can carry a non-.never splitwiseOption from before
            // Splitwise was disconnected — treat as "never split" for this
            // run rather than asking for a friend/share that can only ever
            // fail against a disconnected Splitwise account.
            let effectiveSplitwiseOption = SplitwiseAuthService.currentAccessToken != nil ? splitwiseOption : .never
            guard effectiveSplitwiseOption != .never else {
                // No split — YNAB is committed, so the guard's job is done.
                if let activeDraftId {
                    TransactionDraftGuard.complete(activeDraftId)
                }
                logger.log("perform() done — no split")
                return .result(dialog: "\(dialog)")
            }

            // Splitwise side-split. Repoint the SAME draft — and so the same
            // notification slot — from the now-committed YNAB half to the
            // remaining split, rather than completing one draft and beginning
            // another: a single run must never leave two reminders (ynab +
            // splitwise) able to fire at once. The result is a recoverable
            // Splitwise-only reminder (YNAB is already done), not a YNAB re-do.
            // Resolve the friend as far as possible without asking, up front,
            // so it's on hand both for the split-choice notification and for a
            // background completion; a live ask still happens below when
            // neither an override, the template, nor the app default applies.
            var resolvedFriend: SplitwiseFriendEntity? = splitwiseFriend
                ?? templateFriend.map { SplitwiseFriendEntity(id: $0.id, firstName: $0.firstName, fullName: $0.fullName) }
                ?? (splitwiseFriendFallback == .defaultFriend
                    ? SplitwiseDefaultFriendStore.load().map { SplitwiseFriendEntity(id: $0.id, firstName: $0.firstName, fullName: $0.fullName) }
                    : nil)

            if let activeDraftId {
                TransactionDraftGuard.transition(activeDraftId, to: .splitwiseWallet(merchant: merchant, amount: amount))
            }

            let splitwiseAction: SplitwiseSplitOption
            switch effectiveSplitwiseOption {
            case .never:
                splitwiseAction = .never // unreachable — guarded above
            case .always:
                splitwiseAction = .always
            case .manual:
                splitwiseAction = .manual
            case .ask:
                if let splitwiseRuntimeChoice {
                    splitwiseAction = splitwiseRuntimeChoice
                } else {
                    logger.log("splitwiseOption=ask — requesting runtime choice")
                    // The split is the only thing left and YNAB is already
                    // committed, so an interruption here can be answered
                    // straight from the reminder — arm the Split Equally /
                    // Manually / Don't Split actions (with the resolved friend
                    // + description) for the duration of the question.
                    splitwiseAction = try await TransactionDraftGuard.askSplitChoice(
                        draftId: activeDraftId,
                        context: TransactionDraft.PendingSplitContext(
                            description: payeeName,
                            friendId: resolvedFriend?.id,
                            friendFirstName: resolvedFriend?.firstName,
                            friendFullName: resolvedFriend?.fullName
                        )
                    ) {
                        let splitDescription = payeeName.trimmingCharacters(in: .whitespacesAndNewlines)
                        let prompt: String
                        if splitDescription.isEmpty {
                            prompt = String(localized: "Split this transaction with Splitwise?", table: "AppShortcuts")
                        } else {
                            prompt = String(format: String(localized: "Split this %@ transaction with Splitwise?", table: "AppShortcuts"), splitDescription)
                        }
                        return try await $splitwiseRuntimeChoice.requestValue(IntentDialog(stringLiteral: prompt))
                    }
                    touchDraft()
                }
            }

            guard splitwiseAction != .never else {
                // Chose not to split — the YNAB transaction stands alone.
                if let activeDraftId {
                    TransactionDraftGuard.complete(activeDraftId)
                }
                logger.log("perform() done — not split")
                return .result(dialog: "\(dialog)")
            }

            // Friend still unresolved (fallback was .ask, or nothing
            // configured) — ask live now that we know we're splitting.
            if resolvedFriend == nil, splitwiseFriendFallback == .ask {
                logger.log("splitwiseAction=\(splitwiseAction.rawValue, privacy: .public) — requesting Splitwise friend")
                let friends = try await SplitwiseFriendEntity.defaultQuery.suggestedEntities()
                resolvedFriend = try await $splitwiseFriend.requestDisambiguation(
                    among: friends,
                    dialog: IntentDialog(stringLiteral: String(localized: "Split with which Splitwise friend?"))
                )
                touchDraft()
            }

            guard let friend = resolvedFriend else {
                // No friend to split with and no live-ask path — leave the
                // Splitwise-only draft and nudge the user to finish it in
                // Relay (which resolves the merchant back to this same
                // template and just needs a friend picked).
                logger.log("splitwiseAction=\(splitwiseAction.rawValue, privacy: .public) but no friend available")
                if let activeDraftId {
                    await TransactionDraftGuard.fail(activeDraftId)
                    return .result(dialog: "\(dialog) – no Splitwise friend set, sent a reminder to finish the split in Relay.")
                }
                return .result(dialog: "\(dialog) – no default Splitwise friend set, pick one in Relay or set \"Split With\" for this automation.")
            }

            var resolvedOwnShare: Double? = splitwiseOwnShare
            if splitwiseAction == .manual, resolvedOwnShare == nil {
                logger.log("splitwiseAction=manual — requesting own share")
                let prompt = String(
                    format: String(localized: "Your share of the %@ expense at %@, split with %@?"),
                    formattedAmount,
                    payeeName,
                    friend.firstName
                )
                resolvedOwnShare = try await $splitwiseOwnShare.requestValue(IntentDialog(stringLiteral: prompt))
                touchDraft()
            }
            if splitwiseAction == .manual, let resolvedOwnShare {
                try SplitwiseExpenseHelper.validateOwnShare(resolvedOwnShare, amount: amount)
            }

            let ownShare = (splitwiseAction == .manual) ? resolvedOwnShare : nil
            let fragment = await WalletAutomationDialog.splitDialogFragment(amount: amount, description: payeeName, friend: friend, ownShare: ownShare)
            logger.log("Splitwise split result: \(fragment, privacy: .public)")
            dialog += fragment

            if let activeDraftId {
                TransactionDraftGuard.complete(activeDraftId)
            }

            logger.log("perform() done")
            return .result(dialog: "\(dialog)")
        } catch {
            // The run is ending without finishing whatever's still active —
            // the YNAB write, or the Splitwise split after it — so nudge the
            // user right away rather than waiting out the quiet-period window.
            if let activeDraftId {
                await TransactionDraftGuard.fail(activeDraftId)
            }
            throw error
        }
    }
}
