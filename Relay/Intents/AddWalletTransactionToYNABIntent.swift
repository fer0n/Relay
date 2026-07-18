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

private let logger = Logger(subsystem: "com.pentlandFirth.Relay", category: "WalletTransaction")

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

        let draftId = ensureCompletion
            ? TransactionDraftGuard.begin(.ynabWallet(merchant: merchant, amount: amount, card: card))
            : nil

        // Pushes the "still needs finishing" reminder back out — called
        // after every follow-up question below is answered, so a normal but
        // slow-to-answer run doesn't get a premature nudge mid-flow.
        func touchDraft() {
            if let draftId {
                TransactionDraftGuard.touch(draftId)
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
                    resolvedTemplateChoice = try await $templateChoice.requestValue("Which template for \"\(merchant)\"?")
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
                        newName = try await $newTemplateName.requestValue("Template name?")
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
                    resolvedPayeeName = try await $payeeOverride.requestValue("Payee name for \"\(merchant)\"?")
                    touchDraft()
                }

                let pattern: String
                if let autoMatchPattern {
                    pattern = autoMatchPattern
                } else {
                    logger.log("payeeName=\(resolvedPayeeName, privacy: .public) — requesting auto-match pattern")
                    pattern = try await $autoMatchPattern.requestValue(
                        "Match other merchant names to \(resolvedPayeeName) too? Enter text/regex, or leave blank to skip."
                    )
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
                            dialog: "Category for \(templateName)?"
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
                            dialog: "Split \(templateName) expenses with Splitwise?"
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
                        dialog: "YNAB account for card \"\(card)\"?"
                    )
                    touchDraft()
                }
                logger.log("accountId=\(account.id, privacy: .public)")
                config.cards[card] = account.id
                accountId = account.id
                changed = true
            }

            // A template can carry a non-.never splitwiseOption from before
            // Splitwise was disconnected — treat as "never split" for this
            // run rather than asking for a friend/share that can only ever
            // fail against a disconnected Splitwise account.
            let effectiveSplitwiseOption = SplitwiseAuthService.currentAccessToken != nil ? splitwiseOption : .never

            let splitwiseAction: SplitwiseSplitOption
            switch effectiveSplitwiseOption {
            case .never:
                splitwiseAction = .never
            case .always:
                splitwiseAction = .always
            case .manual:
                splitwiseAction = .manual
            case .ask:
                if let splitwiseRuntimeChoice {
                    splitwiseAction = splitwiseRuntimeChoice
                } else {
                    logger.log("splitwiseOption=ask — requesting runtime choice")
                    splitwiseAction = try await $splitwiseRuntimeChoice.requestValue("Split this \(payeeName) transaction with Splitwise?")
                    touchDraft()
                }
            }

            // splitwiseFriend is a manual per-automation override; when unset,
            // splitwiseFriendFallback decides whether to silently use the
            // app-configured default (ContentView's DefaultSplitwiseFriendRow)
            // or prompt live, so it's opt-in rather than nagging every run.
            var resolvedFriend: SplitwiseFriendEntity? = splitwiseFriend
            if splitwiseAction != .never, resolvedFriend == nil {
                if let templateFriend {
                    logger.log("splitwiseAction=\(splitwiseAction.rawValue, privacy: .public) — using template's Splitwise friend")
                    resolvedFriend = SplitwiseFriendEntity(id: templateFriend.id, firstName: templateFriend.firstName, fullName: templateFriend.fullName)
                } else {
                    switch splitwiseFriendFallback {
                    case .defaultFriend:
                        if let defaultFriend = SplitwiseDefaultFriendStore.load() {
                            logger.log("splitwiseAction=\(splitwiseAction.rawValue, privacy: .public) — using default Splitwise friend")
                            resolvedFriend = SplitwiseFriendEntity(id: defaultFriend.id, firstName: defaultFriend.firstName, fullName: defaultFriend.fullName)
                        }
                    case .ask:
                        logger.log("splitwiseAction=\(splitwiseAction.rawValue, privacy: .public) — requesting Splitwise friend")
                        let friends = try await SplitwiseFriendEntity.defaultQuery.suggestedEntities()
                        resolvedFriend = try await $splitwiseFriend.requestDisambiguation(
                            among: friends,
                            dialog: "Split with which Splitwise friend?"
                        )
                        touchDraft()
                    }
                }
            }
            var resolvedOwnShare: Double? = splitwiseOwnShare
            if splitwiseAction == .manual, resolvedOwnShare == nil {
                logger.log("splitwiseAction=manual — requesting own share")
                let formattedAmount = amount.asMoneyString
                let friendName = resolvedFriend?.firstName ?? "your friend"
                resolvedOwnShare = try await $splitwiseOwnShare.requestValue("Your share of the \(formattedAmount) expense at \(payeeName), split with \(friendName)?")
                touchDraft()
            }
            if splitwiseAction == .manual, let resolvedOwnShare {
                try SplitwiseExpenseHelper.validateOwnShare(resolvedOwnShare, amount: amount)
            }

            if changed {
                do {
                    try WalletTransactionConfigStore.save(config)
                    logger.log("config saved")
                } catch {
                    logger.error("failed to save config: \(String(describing: error), privacy: .public)")
                }
            }

            // Expenses are outflows in YNAB: stored as negative milliunits.
            let milliunits = -Int((amount * 1000).rounded())
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
            logger.log("creating YNAB transaction: accountId=\(accountId, privacy: .public) amountMilliunits=\(milliunits, privacy: .public) payee=\(payeeName, privacy: .public) categoryId=\(categoryId ?? "nil", privacy: .public)")
            let formattedAmount = amount.asMoneyString

            // Never depends on the YNAB call's outcome, so it runs concurrently
            // with it instead of paying for both round-trips back to back.
            // Catches its own errors (never throws) so a Splitwise failure never
            // cancels the still-in-flight YNAB call.
            func createSplitIfNeeded() async -> String? {
                guard splitwiseAction != .never else { return nil }
                guard let friend = resolvedFriend else {
                    logger.log("splitwiseAction=\(splitwiseAction.rawValue, privacy: .public) but no friend available — queuing a draft to finish the split later")
                    // Same treatment as an interrupted run: register a
                    // (Splitwise-only) draft and fire its reminder right
                    // away, since we already know for certain this run
                    // won't complete the split on its own.
                    // ContinueSplitwiseWalletTransactionView resolves the
                    // merchant back to this same template/split-option — the
                    // friend is the only missing piece — and writes the
                    // picked friend back onto the template so future runs
                    // don't hit this again.
                    guard ensureCompletion else {
                        return " – no default Splitwise friend set, pick one in Relay or set \"Split With\" for this automation."
                    }
                    let draftOwnShare = (splitwiseAction == .manual) ? resolvedOwnShare : nil
                    let splitDraftId = TransactionDraftGuard.begin(.splitwiseWallet(merchant: merchant, amount: amount, ownShare: draftOwnShare))
                    TransactionDraftGuard.fail(splitDraftId)
                    return " – no default Splitwise friend set, sent a reminder to finish the split in Relay."
                }
                let ownShare = (splitwiseAction == .manual) ? resolvedOwnShare : nil
                let fragment = await WalletAutomationDialog.splitDialogFragment(amount: amount, description: payeeName, friend: friend, ownShare: ownShare)
                logger.log("Splitwise split result: \(fragment, privacy: .public)")
                return fragment
            }

            async let ynabOutcome = PendingSync.createYNABTransaction(transaction, token: token, summary: "\(formattedAmount) at \(payeeName)")
            async let splitDialogFragment = createSplitIfNeeded()

            let outcome = try await ynabOutcome
            var dialog = WalletAutomationDialog.handleYNABOutcome(outcome, formattedAmount: formattedAmount, payeeName: payeeName, categoryId: categoryId)
            logger.log("YNAB result: \(dialog, privacy: .public)")

            if let fragment = await splitDialogFragment {
                dialog += fragment
            }

            if let draftId {
                TransactionDraftGuard.complete(draftId)
            }

            logger.log("perform() done")
            return .result(dialog: "\(dialog)")
        } catch {
            // The run is ending without a created/queued transaction —
            // no reason to wait out the usual quiet-period window once
            // that's certain, so nudge the user right away instead.
            if let draftId {
                TransactionDraftGuard.fail(draftId)
            }
            throw error
        }
    }
}
