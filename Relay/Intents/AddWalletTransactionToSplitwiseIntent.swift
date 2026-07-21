//
//  AddWalletTransactionToSplitwiseIntent.swift
//  Relay
//
//  Sibling to AddWalletTransactionToYNABIntent for a card/account used
//  purely for shared expenses: wired as the action of a Shortcuts
//  "Transaction" Personal Automation (receiving Merchant/Amount magic
//  variables), but creates a Splitwise expense directly — no YNAB
//  transaction at all. Remembers merchant -> friend/split-mode via the same
//  per-merchant "template" pattern as the YNAB intent, backed by the same
//  WalletTransactionConfigStore — a template created by either intent works
//  for both, so the same bucket (e.g. "Supermarkt") can be used whether a
//  given transaction goes to YNAB, straight to Splitwise, or both.
//
//  Unlike AddWalletTransactionToYNABIntent (where the friend is asked live
//  whenever the template doesn't already have one, since splitting is a
//  side effect of a YNAB transaction there), this intent's whole point is
//  splitting — so a friend it has to ask for gets written back onto the
//  template once resolved, fixing it for next time rather than re-asking.
//
//  Built entirely with the async requestValue/requestDisambiguation style
//  (perform() never restarts, so there's no duplicate-expense risk from a
//  restart). requestValue params must stay listed in parameterSummary —
//  on iOS 18+ it throws a connection error otherwise (see the equivalent
//  note in AddWalletTransactionToYNABIntent.swift) — while
//  requestDisambiguation params (friendOverride, splitOptionOverride) are
//  resolved with their candidates passed inline, so they can stay hidden.
//

import AppIntents
import os

private let logger = Logger(subsystem: "com.octabits.relay", category: "WalletTransactionSplitwise")

nonisolated struct AddWalletTransactionToSplitwiseIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Wallet Transaction to Splitwise"
    static let description = IntentDescription(
        "Adds a Splitwise expense from a Wallet transaction, remembering friend/split choices for next time."
    )

    @Parameter(title: "Merchant")
    var merchant: String

    @Parameter(title: "Amount")
    var amount: Double

    @Parameter(title: "Template", optionsProvider: TemplateOptionsProvider())
    var templateChoice: String?

    @Parameter(title: "Template Name")
    var newTemplateName: String?

    @Parameter(title: "Description")
    var descriptionOverride: String?

    @Parameter(title: "Auto-Match Pattern")
    var autoMatchPattern: String?

    @Parameter(title: "Split With")
    var friendOverride: SplitwiseFriendEntity?

    @Parameter(title: "If Split With Isn't Set", default: .defaultFriend)
    var splitwiseFriendFallback: SplitwiseFriendFallback

    @Parameter(title: "Split")
    var splitOptionOverride: SplitwiseTemplateOption?

    @Parameter(title: "Your Share", description: "Only used when Split is Manual")
    var splitwiseOwnShare: Double?

    /// Only used when the resolved template's split option is "Ask Each
    /// Time" — the live per-transaction equivalent of the original's
    /// Ja/Manuell/Nein menu.
    @Parameter(title: "Split Transaction?")
    var splitwiseRuntimeChoice: SplitwiseSplitOption?

    /// See TransactionDraftGuard: if this run gets interrupted (a follow-up
    /// question dismissed/timed out, the process killed by a screen lock)
    /// before the expense is actually created, a local notification nudges
    /// the user to go finish it — since there's no way to resume a
    /// suspended perform() call.
    @Parameter(title: "Ensure Completion", description: "If this run is interrupted before finishing, send a notification to continue it later.", default: true)
    var ensureCompletion: Bool

    @Parameter(title: "Success Notification", description: "When this action finishes successfully, send a confirmation notification.", default: true)
    var successNotification: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$amount) Splitwise expense for \(\.$merchant)") {
            \.$templateChoice
            \.$newTemplateName
            \.$descriptionOverride
            \.$autoMatchPattern
            \.$friendOverride
            \.$splitwiseFriendFallback
            \.$splitwiseOwnShare
            \.$splitwiseRuntimeChoice
            \.$ensureCompletion
            \.$successNotification
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        logger.log("perform() start — merchant=\(merchant, privacy: .public) amount=\(amount, privacy: .public)")

        let draftId = ensureCompletion
            ? TransactionDraftGuard.begin(.splitwiseWallet(merchant: merchant, amount: amount))
            : nil

        // Pushes the "still needs finishing" reminder back out — called
        // after every follow-up question below is answered, so a normal but
        // slow-to-answer run doesn't get a premature nudge mid-flow.
        func touchDraft() {
            if let draftId {
                TransactionDraftGuard.touch(draftId)
            }
        }

        // Resolves a friend to split with: uses `existing` (a template's
        // already-cached friend) if there is one, otherwise a manual
        // override via the shortcut parameter, otherwise the app-wide
        // default friend, otherwise asks live.
        func resolveFriend(existing: (id: Int, firstName: String, fullName: String)?, dialog: IntentDialog) async throws -> (id: Int, firstName: String, fullName: String) {
            if let existing { return existing }
            let friend: SplitwiseFriendEntity
            if let friendOverride {
                friend = friendOverride
            } else if splitwiseFriendFallback == .defaultFriend, let defaultFriend = SplitwiseDefaultFriendStore.load() {
                logger.log("using app-wide default Splitwise friend")
                friend = SplitwiseFriendEntity(id: defaultFriend.id, firstName: defaultFriend.firstName, fullName: defaultFriend.fullName)
            } else {
                logger.log("requesting Splitwise friend")
                let friends = try await SplitwiseFriendEntity.defaultQuery.suggestedEntities()
                friend = try await $friendOverride.requestDisambiguation(
                    among: friends,
                    dialog: dialog
                )
                touchDraft()
            }
            return (friend.id, friend.firstName, friend.fullName)
        }

        do {
            await PendingOperationQueue.shared.flush()

            guard SplitwiseAuthService.currentAccessToken != nil else {
                logger.error("no Splitwise access token in Keychain — not authenticated")
                throw SplitwiseIntentError.notAuthenticated
            }

            var config = WalletTransactionConfigStore.load()
            var changed = false

            let expenseDescription: String
            let friendId: Int
            let friendFirstName: String
            let friendFullName: String
            let splitOption: SplitwiseTemplateOption

            if let info = config.resolvedMerchantInfo(for: merchant) {
                logger.log("merchant resolved to description=\(info.payeeName, privacy: .public) template=\(info.templateName, privacy: .public)")
                if config.merchants[merchant] == nil {
                    config.merchants[merchant] = info
                    changed = true
                }
                expenseDescription = info.payeeName
                let template = config.templates[info.templateName]
                splitOption = template?.splitwiseOption ?? .never

                let resolved = try await resolveFriend(
                    existing: template?.splitwiseFriend,
                    dialog: "Split \(info.templateName) expenses with which friend?"
                )
                friendId = resolved.id
                friendFirstName = resolved.firstName
                friendFullName = resolved.fullName
                if template?.splitwiseFriend == nil {
                    // The template didn't have a friend yet (e.g. it was
                    // only ever used from the YNAB intent) — fix it now so
                    // future runs skip asking, same as a freshly-created
                    // template below.
                    var updated = template ?? WalletTransactionConfig.Template()
                    updated.splitwiseFriendId = resolved.id
                    updated.splitwiseFriendFirstName = resolved.firstName
                    updated.splitwiseFriendFullName = resolved.fullName
                    config.templates[info.templateName] = updated
                    changed = true
                }
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

                let resolvedDescription: String
                if let descriptionOverride {
                    resolvedDescription = descriptionOverride
                } else {
                    logger.log("template=\(templateName, privacy: .public) — requesting description")
                    let prompt = String(format: String(localized: "Description for \"%@\"?"), merchant)
                    resolvedDescription = try await $descriptionOverride.requestValue(IntentDialog(stringLiteral: prompt))
                    touchDraft()
                }

                let pattern: String
                if let autoMatchPattern {
                    pattern = autoMatchPattern
                } else {
                    logger.log("description=\(resolvedDescription, privacy: .public) — requesting auto-match pattern")
                    let prompt = String(
                        format: String(localized: "Match other merchant names to %@ too? Enter text/regex, or leave blank to skip."),
                        resolvedDescription
                    )
                    pattern = try await $autoMatchPattern.requestValue(IntentDialog(stringLiteral: prompt))
                    touchDraft()
                }
                logger.log("autoMatchPattern=\"\(pattern, privacy: .public)\"")

                let resolvedFriend = try await resolveFriend(
                    existing: existingTemplate?.splitwiseFriend,
                    dialog: IntentDialog(stringLiteral: String(format: String(localized: "Split %@ expenses with which friend?"), templateName))
                )

                let resolvedSplitOption: SplitwiseTemplateOption
                if let existingTemplate {
                    resolvedSplitOption = existingTemplate.splitwiseOption
                } else {
                    if let splitOptionOverride {
                        resolvedSplitOption = splitOptionOverride
                    } else {
                        logger.log("template=\(templateName, privacy: .public) — requesting split option")
                        resolvedSplitOption = try await $splitOptionOverride.requestDisambiguation(
                            among: [.ask, .always, .manual, .never],
                            dialog: IntentDialog(stringLiteral: String(format: String(localized: "Split %@ expenses with Splitwise?"), templateName))
                        )
                        touchDraft()
                    }
                }

                var template = existingTemplate ?? WalletTransactionConfig.Template()
                template.splitwiseFriendId = resolvedFriend.id
                template.splitwiseFriendFirstName = resolvedFriend.firstName
                template.splitwiseFriendFullName = resolvedFriend.fullName
                template.splitwiseOption = resolvedSplitOption
                if !pattern.isEmpty {
                    template.autoMatch.append(.init(pattern: pattern, payeeName: resolvedDescription))
                }
                config.templates[templateName] = template
                config.merchants[merchant] = WalletTransactionConfig.MerchantInfo(
                    payeeName: resolvedDescription,
                    templateName: templateName
                )
                expenseDescription = resolvedDescription
                friendId = resolvedFriend.id
                friendFirstName = resolvedFriend.firstName
                friendFullName = resolvedFriend.fullName
                splitOption = resolvedSplitOption
                changed = true
            }

            // Persist the resolved template/friend/merchant mappings before
            // the (interruptible) split question, so they're remembered even
            // when this run is finished from the notification instead of here.
            if changed {
                do {
                    try WalletTransactionConfigStore.save(config)
                    logger.log("config saved")
                } catch {
                    logger.error("failed to save config: \(String(describing: error), privacy: .public)")
                }
            }

            let splitwiseAction: SplitwiseSplitOption
            switch splitOption {
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
                    logger.log("splitOption=ask — requesting runtime choice")
                    // Description + friend are already resolved, so an
                    // interruption at this question can be answered straight
                    // from the reminder. Unlike the YNAB automation nothing is
                    // committed ahead of the split (the expense *is* the
                    // split), so a dismiss defers (the draft stays) rather than
                    // completing; Don't Split resolves it with no expense.
                    splitwiseAction = try await TransactionDraftGuard.askSplitChoice(
                        draftId: draftId,
                        context: TransactionDraft.PendingSplitContext(
                            description: expenseDescription,
                            friendId: friendId,
                            friendFirstName: friendFirstName,
                            friendFullName: friendFullName
                        )
                    ) {
                        let splitDescription = expenseDescription.trimmingCharacters(in: .whitespacesAndNewlines)
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
                logger.log("splitwiseAction=never — skipping Splitwise")
                if let draftId {
                    TransactionDraftGuard.complete(draftId)
                }
                let dialog = WalletAutomationDialog.splitwiseSkippedDialog(description: expenseDescription)
                if successNotification {
                    WalletCompletionNotification.postConfirmation(dialog: dialog)
                }
                return .result(dialog: "\(dialog)")
            }

            var resolvedOwnShare: Double? = splitwiseOwnShare
            if splitwiseAction == .manual, resolvedOwnShare == nil {
                logger.log("splitwiseAction=manual — requesting own share")
                let formattedAmount = amount.asMoneyString
                let prompt = String(
                    format: String(localized: "Your share of the %@ expense at %@, split with %@?"),
                    formattedAmount,
                    expenseDescription,
                    friendFirstName
                )
                resolvedOwnShare = try await $splitwiseOwnShare.requestValue(IntentDialog(stringLiteral: prompt))
                touchDraft()
            }
            if splitwiseAction == .manual, let resolvedOwnShare {
                try SplitwiseExpenseHelper.validateOwnShare(resolvedOwnShare, amount: amount)
            }

            let formattedAmount = amount.asMoneyString
            do {
                let outcome = try await SplitwiseExpenseHelper.addExpense(
                    amount: amount,
                    description: expenseDescription,
                    friend: SplitwiseFriendEntity(id: friendId, firstName: friendFirstName, fullName: friendFullName),
                    ownShare: (splitwiseAction == .manual) ? resolvedOwnShare : nil
                )
                if let draftId {
                    TransactionDraftGuard.complete(draftId)
                }
                let dialog = WalletAutomationDialog.splitwiseWalletDialog(outcome: outcome, formattedAmount: formattedAmount, description: expenseDescription)
                if successNotification {
                    WalletCompletionNotification.postConfirmation(dialog: dialog, historyEntryID: TransactionHistoryStore.newestEntryID())
                }
                logger.log("Splitwise result: \(dialog, privacy: .public)")
                return .result(dialog: "\(dialog)")
            } catch {
                logger.error("Splitwise addExpense failed: \(String(describing: error), privacy: .public)")
                // addExpense already throws a well-formed SplitwiseIntentError in
                // most cases (validation, not-authenticated, mapped API errors) —
                // re-mapping those through `.from` again would lose the specific
                // reason, since `.from` only pattern-matches the raw API errors.
                throw (error as? SplitwiseIntentError) ?? SplitwiseIntentError.from(error)
            }
        } catch {
            // The run is ending without a created/queued expense — no
            // reason to wait out the usual quiet-period window once
            // that's certain, so nudge the user right away instead.
            if let draftId {
                await TransactionDraftGuard.fail(draftId)
            }
            throw error
        }
    }
}
