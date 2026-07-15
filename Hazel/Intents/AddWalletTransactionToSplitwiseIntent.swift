//
//  AddWalletTransactionToSplitwiseIntent.swift
//  Hazel
//
//  Sibling to AddWalletTransactionToYNABIntent for a card/account used
//  purely for shared expenses: wired as the action of a Shortcuts
//  "Transaction" Personal Automation (receiving Merchant/Amount magic
//  variables), but creates a Splitwise expense directly — no YNAB
//  transaction at all. Remembers merchant -> friend/split-mode via the
//  same per-merchant "template" pattern as the YNAB intent, backed by
//  SplitwiseWalletTransactionConfigStore.
//
//  Unlike AddWalletTransactionToYNABIntent (where the Splitwise friend is
//  asked live on every transaction, never cached), the friend here is
//  fixed on the template and never re-asked once set — this intent's
//  whole point is splitting, so "who to split with" is a merchant-level
//  setup choice, not a per-run one.
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

private let logger = Logger(subsystem: "com.pentlandFirth.Hazel", category: "WalletTransactionSplitwise")

private let createNewTemplateOption = "Create New Template"

nonisolated struct SplitwiseTemplateOptionsProvider: DynamicOptionsProvider {
    func results() async throws -> [String] {
        let config = SplitwiseWalletTransactionConfigStore.load()
        return [createNewTemplateOption] + config.templates.keys.sorted()
    }
}

nonisolated struct AddWalletTransactionToSplitwiseIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Wallet Transaction to Splitwise"
    static let description = IntentDescription(
        "Adds a Splitwise expense from a Wallet transaction, remembering friend/split choices for next time."
    )

    @Parameter(title: "Merchant")
    var merchant: String

    @Parameter(title: "Amount")
    var amount: Double

    @Parameter(title: "Template", optionsProvider: SplitwiseTemplateOptionsProvider())
    var templateChoice: String?

    @Parameter(title: "Template Name")
    var newTemplateName: String?

    @Parameter(title: "Description")
    var descriptionOverride: String?

    @Parameter(title: "Auto-Match Pattern")
    var autoMatchPattern: String?

    @Parameter(title: "Split With")
    var friendOverride: SplitwiseFriendEntity?

    @Parameter(title: "Split")
    var splitOptionOverride: SplitwiseTemplateOption?

    @Parameter(title: "Your Share", description: "Only used when Split is Manual")
    var splitwiseOwnShare: Double?

    /// Only used when the resolved template's split option is "Ask Each
    /// Time" — the live per-transaction equivalent of the original's
    /// Ja/Manuell/Nein menu.
    @Parameter(title: "Split This Transaction?")
    var splitwiseRuntimeChoice: SplitwiseSplitOption?

    /// See TransactionDraftGuard: if this run gets interrupted (a follow-up
    /// question dismissed/timed out, the process killed by a screen lock)
    /// before the expense is actually created, a local notification nudges
    /// the user to go finish it — since there's no way to resume a
    /// suspended perform() call.
    @Parameter(title: "Ensure Completion", description: "If this run is interrupted before finishing, send a notification to continue it later.", default: true)
    var ensureCompletion: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$amount) Splitwise expense for \(\.$merchant)") {
            \.$templateChoice
            \.$newTemplateName
            \.$descriptionOverride
            \.$autoMatchPattern
            \.$splitwiseOwnShare
            \.$splitwiseRuntimeChoice
            \.$ensureCompletion
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

        await PendingOperationQueue.shared.flush()

        guard SplitwiseAuthService.currentAccessToken != nil else {
            logger.error("no Splitwise access token in Keychain — not authenticated")
            throw SplitwiseIntentError.notAuthenticated
        }

        var config = SplitwiseWalletTransactionConfigStore.load()
        var changed = false

        let expenseDescription: String
        let friendId: Int
        let friendFirstName: String
        let friendFullName: String
        let splitOption: SplitwiseTemplateOption

        if let info = config.resolvedMerchantInfo(for: merchant) {
            logger.log("merchant resolved to description=\(info.expenseDescription, privacy: .public) template=\(info.templateName, privacy: .public)")
            if config.merchants[merchant] == nil {
                config.merchants[merchant] = info
                changed = true
            }
            expenseDescription = info.expenseDescription
            let template = config.templates[info.templateName]
            friendId = template?.friendId ?? 0
            friendFirstName = template?.friendFirstName ?? ""
            friendFullName = template?.friendFullName ?? ""
            splitOption = template?.splitOption ?? .never
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
            let existingTemplate: SplitwiseWalletTransactionConfig.Template?
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

            let resolvedDescription: String
            if let descriptionOverride {
                resolvedDescription = descriptionOverride
            } else {
                logger.log("template=\(templateName, privacy: .public) — requesting description")
                resolvedDescription = try await $descriptionOverride.requestValue("Description for \"\(merchant)\"?")
                touchDraft()
            }

            let pattern: String
            if let autoMatchPattern {
                pattern = autoMatchPattern
            } else {
                logger.log("description=\(resolvedDescription, privacy: .public) — requesting auto-match pattern")
                pattern = try await $autoMatchPattern.requestValue(
                    "Match other merchant names to \(resolvedDescription) too? Enter text/regex, or leave blank to skip."
                )
                touchDraft()
            }
            logger.log("autoMatchPattern=\"\(pattern, privacy: .public)\"")

            let resolvedFriendId: Int
            let resolvedFriendFirstName: String
            let resolvedFriendFullName: String
            if let existingTemplate {
                resolvedFriendId = existingTemplate.friendId
                resolvedFriendFirstName = existingTemplate.friendFirstName
                resolvedFriendFullName = existingTemplate.friendFullName
            } else {
                let friend: SplitwiseFriendEntity
                if let friendOverride {
                    friend = friendOverride
                } else {
                    logger.log("template=\(templateName, privacy: .public) — requesting Splitwise friend")
                    let friends = try await SplitwiseFriendEntity.defaultQuery.suggestedEntities()
                    friend = try await $friendOverride.requestDisambiguation(
                        among: friends,
                        dialog: "Split \(templateName) expenses with which friend?"
                    )
                    touchDraft()
                }
                resolvedFriendId = friend.id
                resolvedFriendFirstName = friend.firstName
                resolvedFriendFullName = friend.fullName
            }

            let resolvedSplitOption: SplitwiseTemplateOption
            if let existingTemplate {
                resolvedSplitOption = existingTemplate.splitOption
            } else {
                if let splitOptionOverride {
                    resolvedSplitOption = splitOptionOverride
                } else {
                    logger.log("template=\(templateName, privacy: .public) — requesting split option")
                    resolvedSplitOption = try await $splitOptionOverride.requestDisambiguation(
                        among: [.ask, .always, .manual, .never],
                        dialog: "Split \(templateName) expenses with Splitwise?"
                    )
                    touchDraft()
                }
            }

            var template = existingTemplate ?? SplitwiseWalletTransactionConfig.Template(
                friendId: resolvedFriendId,
                friendFirstName: resolvedFriendFirstName,
                friendFullName: resolvedFriendFullName,
                splitOption: resolvedSplitOption
            )
            if !pattern.isEmpty {
                template.autoMatch.append(.init(pattern: pattern, expenseDescription: resolvedDescription))
            }
            config.templates[templateName] = template
            config.merchants[merchant] = SplitwiseWalletTransactionConfig.MerchantInfo(
                expenseDescription: resolvedDescription,
                templateName: templateName
            )
            expenseDescription = resolvedDescription
            friendId = resolvedFriendId
            friendFirstName = resolvedFriendFirstName
            friendFullName = resolvedFriendFullName
            splitOption = resolvedSplitOption
            changed = true
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
                splitwiseAction = try await $splitwiseRuntimeChoice.requestValue("Split this \(expenseDescription) transaction with Splitwise?")
                touchDraft()
            }
        }

        if changed {
            do {
                try SplitwiseWalletTransactionConfigStore.save(config)
                logger.log("config saved")
            } catch {
                logger.error("failed to save config: \(String(describing: error), privacy: .public)")
            }
        }

        guard splitwiseAction != .never else {
            logger.log("splitwiseAction=never — skipping Splitwise")
            if let draftId {
                TransactionDraftGuard.complete(draftId)
            }
            return .result(dialog: "\(WalletAutomationDialog.splitwiseSkippedDialog(description: expenseDescription))")
        }

        var resolvedOwnShare: Double? = splitwiseOwnShare
        if splitwiseAction == .manual, resolvedOwnShare == nil {
            logger.log("splitwiseAction=manual — requesting own share")
            let formattedAmount = amount.formatted(.number.precision(.fractionLength(2)))
            resolvedOwnShare = try await $splitwiseOwnShare.requestValue("Your share of the \(formattedAmount) expense at \(expenseDescription), split with \(friendFirstName)?")
            touchDraft()
        }
        if splitwiseAction == .manual, let resolvedOwnShare {
            try SplitwiseExpenseHelper.validateOwnShare(resolvedOwnShare, amount: amount)
        }

        let formattedAmount = amount.formatted(.number.precision(.fractionLength(2)))
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
    }
}
