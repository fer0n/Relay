//
//  AddWalletTransactionToYNABIntent.swift
//  Hazel
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

import AppIntents
import os

private let logger = Logger(subsystem: "com.pentlandFirth.Hazel", category: "WalletTransaction")

private let createNewTemplateOption = "Create New Template"

nonisolated struct TemplateOptionsProvider: DynamicOptionsProvider {
    func results() async throws -> [String] {
        let config = WalletTransactionConfigStore.load()
        return [createNewTemplateOption] + config.templates.keys.sorted()
    }
}

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

    @Parameter(title: "Category")
    var categoryOverride: YNABCategoryEntity?

    @Parameter(title: "Auto-Match Pattern")
    var autoMatchPattern: String?

    @Parameter(title: "Account")
    var accountOverride: YNABAccountEntity?

    @Parameter(title: "Split with Splitwise")
    var splitwiseOptionOverride: SplitwiseTemplateOption?

    @Parameter(title: "Split With")
    var splitwiseFriend: SplitwiseFriendEntity?

    @Parameter(title: "Your Splitwise Share", description: "Only used when Split with Splitwise is Manual")
    var splitwiseOwnShare: Double?

    /// Only used when the resolved template's Splitwise option is "Ask
    /// Each Time" — the live per-transaction equivalent of the original's
    /// Ja/Manuell/Nein menu.
    @Parameter(title: "Split This Transaction?")
    var splitwiseRuntimeChoice: SplitwiseSplitOption?

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$amount) at \(\.$merchant) to YNAB") {
            \.$card
            \.$templateChoice
            \.$newTemplateName
            \.$payeeOverride
            \.$categoryOverride
            \.$autoMatchPattern
            \.$accountOverride
            \.$splitwiseOptionOverride
            \.$splitwiseFriend
            \.$splitwiseOwnShare
            \.$splitwiseRuntimeChoice
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        logger.log("perform() start — merchant=\(merchant, privacy: .public) amount=\(amount, privacy: .public) card=\(card, privacy: .public)")

        guard let token = YNABAuthService.currentAccessToken else {
            logger.error("no YNAB access token in Keychain — not authenticated")
            throw YNABIntentError.notAuthenticated
        }
        logger.log("YNAB token present (len=\(token.count, privacy: .public))")

        var config = WalletTransactionConfigStore.load()
        var changed = false

        let payeeName: String
        let categoryId: String?
        let splitwiseOption: SplitwiseTemplateOption

        if let info = config.resolvedMerchantInfo(for: merchant) {
            logger.log("merchant resolved to payee=\(info.payeeName, privacy: .public) template=\(info.templateName, privacy: .public)")
            if config.merchants[merchant] == nil {
                config.merchants[merchant] = info
                changed = true
            }
            payeeName = info.payeeName
            categoryId = config.templates[info.templateName]?.categoryId
            splitwiseOption = config.templates[info.templateName]?.splitwiseOption ?? .never
        } else {
            guard let templateChoice else {
                logger.log("no merchant match — requesting template choice")
                throw $templateChoice.requestValue("Which template for \"\(merchant)\"?")
            }

            let templateName: String
            let existingTemplate: WalletTransactionConfig.Template?
            if templateChoice != createNewTemplateOption, let existing = config.templates[templateChoice] {
                templateName = templateChoice
                existingTemplate = existing
            } else {
                guard let newName = newTemplateName else {
                    logger.log("creating new template — requesting template name")
                    throw $newTemplateName.requestValue("Template name?")
                }
                templateName = newName
                existingTemplate = config.templates[newName]
            }

            guard let resolvedPayeeName = payeeOverride else {
                logger.log("template=\(templateName, privacy: .public) — requesting payee name")
                throw $payeeOverride.requestValue("Payee name for \"\(merchant)\"?")
            }

            let resolvedCategoryId: String?
            if let existingTemplate {
                resolvedCategoryId = existingTemplate.categoryId
            } else {
                guard let category = categoryOverride else {
                    logger.log("payeeName=\(resolvedPayeeName, privacy: .public) — requesting category")
                    throw $categoryOverride.requestValue("Category for \(templateName)?")
                }
                resolvedCategoryId = category.id
            }

            let resolvedSplitwiseOption: SplitwiseTemplateOption
            if let existingTemplate {
                resolvedSplitwiseOption = existingTemplate.splitwiseOption
            } else {
                guard let splitOption = splitwiseOptionOverride else {
                    logger.log("categoryId=\(resolvedCategoryId ?? "nil", privacy: .public) — requesting Splitwise option")
                    throw $splitwiseOptionOverride.requestValue("Split \(templateName) expenses with Splitwise?")
                }
                resolvedSplitwiseOption = splitOption
            }

            guard let pattern = autoMatchPattern else {
                logger.log("categoryId=\(resolvedCategoryId ?? "nil", privacy: .public) — requesting auto-match pattern")
                throw $autoMatchPattern.requestValue(
                    "Match other merchant names to \(resolvedPayeeName) too? Enter text/regex, or leave blank to skip."
                )
            }
            logger.log("autoMatchPattern=\"\(pattern, privacy: .public)\"")

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
            changed = true
        }

        let accountId: String
        if let existingAccountId = config.cards[card] {
            logger.log("card matched existing accountId=\(existingAccountId, privacy: .public)")
            accountId = existingAccountId
        } else {
            guard let account = accountOverride else {
                logger.log("no account match for card — requesting account")
                throw $accountOverride.requestValue("YNAB account for card \"\(card)\"?")
            }
            logger.log("accountId=\(account.id, privacy: .public)")
            config.cards[card] = account.id
            accountId = account.id
            changed = true
        }

        // Resolve all needed values before the mutating calls below: throwing
        // requestValue re-runs perform() from the top, which would otherwise
        // create a second, duplicate YNAB transaction.
        let splitwiseAction: SplitwiseSplitOption
        switch splitwiseOption {
        case .never:
            splitwiseAction = .never
        case .always:
            splitwiseAction = .always
        case .manual:
            splitwiseAction = .manual
        case .ask:
            guard let choice = splitwiseRuntimeChoice else {
                logger.log("splitwiseOption=ask — requesting runtime choice")
                throw $splitwiseRuntimeChoice.requestValue("Split this \(payeeName) transaction with Splitwise?")
            }
            splitwiseAction = choice
        }

        if splitwiseAction != .never, splitwiseFriend == nil {
            logger.log("splitwiseAction=\(splitwiseAction.rawValue, privacy: .public) — requesting Splitwise friend")
            throw $splitwiseFriend.requestValue("Split with which Splitwise friend?")
        }
        if splitwiseAction == .manual, splitwiseOwnShare == nil {
            logger.log("splitwiseAction=manual — requesting own share")
            throw $splitwiseOwnShare.requestValue("Your share of the expense?")
        }

        if changed {
            do {
                try WalletTransactionConfigStore.save(config)
                logger.log("config saved")
            } catch {
                logger.error("failed to save config: \(String(describing: error), privacy: .public)")
            }
        }

        do {
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
            try await YNABService.createTransaction(transaction, token: token)
            logger.log("YNAB transaction created successfully")
        } catch {
            logger.error("YNAB createTransaction failed: \(String(describing: error), privacy: .public)")
            throw YNABIntentError.from(error)
        }

        let formattedAmount = amount.formatted(.number.precision(.fractionLength(2)))
        var dialog = "Added \(formattedAmount) at \(payeeName)"

        if splitwiseAction != .never, let friend = splitwiseFriend {
            let ownShare = (splitwiseAction == .manual) ? splitwiseOwnShare : nil
            do {
                let shareSummary = try await SplitwiseExpenseHelper.addExpense(
                    amount: amount,
                    description: payeeName,
                    friend: friend,
                    ownShare: ownShare
                )
                logger.log("Splitwise expense created: \(shareSummary, privacy: .public)")
                dialog += ", split with Splitwise — \(shareSummary)"
            } catch {
                let message = (error as? SplitwiseIntentError)?.localizedStringResource
                    ?? "Couldn't add the Splitwise expense."
                logger.error("Splitwise split failed: \(String(describing: error), privacy: .public)")
                dialog += ". \(String(localized: message))"
            }
        }

        logger.log("perform() done")
        return .result(dialog: "\(dialog)")
    }
}
