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
    @Parameter(title: "Split This Transaction?")
    var splitwiseRuntimeChoice: SplitwiseSplitOption?

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
            let resolvedTemplateChoice: String
            if let templateChoice {
                resolvedTemplateChoice = templateChoice
            } else {
                logger.log("no merchant match — requesting template choice")
                resolvedTemplateChoice = try await $templateChoice.requestValue("Which template for \"\(merchant)\"?")
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
            }

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
                }
                resolvedCategoryId = category.id
            }

            let resolvedSplitwiseOption: SplitwiseTemplateOption
            if let existingTemplate {
                resolvedSplitwiseOption = existingTemplate.splitwiseOption
            } else {
                if let splitwiseOptionOverride {
                    resolvedSplitwiseOption = splitwiseOptionOverride
                } else {
                    logger.log("categoryId=\(resolvedCategoryId ?? "nil", privacy: .public) — requesting Splitwise option")
                    // .manual is deliberately left out here — Ask/Split
                    // Equally/Don't Split cover template setup; a template
                    // already saved as .manual (from before, or set via
                    // splitwiseOptionOverride) still works, just isn't
                    // offered as a fresh choice.
                    resolvedSplitwiseOption = try await $splitwiseOptionOverride.requestDisambiguation(
                        among: [.ask, .always, .never],
                        dialog: "Split \(templateName) expenses with Splitwise?"
                    )
                }
            }

            let pattern: String
            if let autoMatchPattern {
                pattern = autoMatchPattern
            } else {
                logger.log("categoryId=\(resolvedCategoryId ?? "nil", privacy: .public) — requesting auto-match pattern")
                pattern = try await $autoMatchPattern.requestValue(
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
            }
            logger.log("accountId=\(account.id, privacy: .public)")
            config.cards[card] = account.id
            accountId = account.id
            changed = true
        }

        let splitwiseAction: SplitwiseSplitOption
        switch splitwiseOption {
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
            }
        }

        // splitwiseFriend is a manual per-automation override; when unset,
        // splitwiseFriendFallback decides whether to silently use the
        // app-configured default (ContentView's DefaultSplitwiseFriendRow)
        // or prompt live, so it's opt-in rather than nagging every run.
        var resolvedFriend: SplitwiseFriendEntity? = splitwiseFriend
        if splitwiseAction != .never, resolvedFriend == nil {
            switch splitwiseFriendFallback {
            case .defaultFriend:
                if let defaultFriend = SplitwiseDefaultFriendStore.load() {
                    logger.log("splitwiseAction=\(splitwiseAction.rawValue, privacy: .public) — using default Splitwise friend")
                    resolvedFriend = SplitwiseFriendEntity(id: defaultFriend.id, name: defaultFriend.name)
                }
            case .ask:
                logger.log("splitwiseAction=\(splitwiseAction.rawValue, privacy: .public) — requesting Splitwise friend")
                let friends = try await SplitwiseFriendEntity.defaultQuery.suggestedEntities()
                resolvedFriend = try await $splitwiseFriend.requestDisambiguation(
                    among: friends,
                    dialog: "Split with which Splitwise friend?"
                )
            }
        }
        var resolvedOwnShare: Double? = splitwiseOwnShare
        if splitwiseAction == .manual, resolvedOwnShare == nil {
            logger.log("splitwiseAction=manual — requesting own share")
            resolvedOwnShare = try await $splitwiseOwnShare.requestValue("Your share of the expense?")
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
            if let categoryId {
                YNABCategoryUsageStore.recordUsage(categoryId: categoryId)
            }
        } catch {
            logger.error("YNAB createTransaction failed: \(String(describing: error), privacy: .public)")
            throw YNABIntentError.from(error)
        }

        let formattedAmount = amount.formatted(.number.precision(.fractionLength(2)))
        var dialog = "Added \(formattedAmount) at \(payeeName)"

        if splitwiseAction != .never, let friend = resolvedFriend {
            let ownShare = (splitwiseAction == .manual) ? resolvedOwnShare : nil
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
        } else if splitwiseAction != .never {
            logger.log("splitwiseAction=\(splitwiseAction.rawValue, privacy: .public) but no friend available — skipping split")
            dialog += ". No default Splitwise friend set — pick one in Hazel, or set \"Split With\" for this automation."
        }

        logger.log("perform() done")
        return .result(dialog: "\(dialog)")
    }
}
