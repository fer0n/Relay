//
//  AddWalletTransactionToYNABIntent.swift
//  Relay
//
//  Action of a Shortcuts "Transaction" Personal Automation, receiving the
//  Wallet transaction's Merchant/Amount/Card magic variables directly.
//  Replaces the Shortcut described in docs/project-goals.md.
//
//  A mapped merchant runs straight through; anything needing setup is parked
//  as a draft for ContinueWalletTransactionView, which keeps this intent's
//  only live question to "which template?".
//

import AppIntents
import os

private nonisolated let logger = Logger(subsystem: Const.loggerSubsystem, category: "WalletTransaction")

struct AddWalletTransactionToYNABIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Wallet Transaction to YNAB"
    static let description = IntentDescription(
        "Adds a YNAB transaction from a Wallet transaction, remembering payee/category/account choices for next time."
    )

    // `.dynamic` only adds the option of asking to come forward mid-run, used
    // in exactly one place — see openDraftInRelay.
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

    @Parameter(title: "Merchant")
    var merchant: String

    @Parameter(title: "Amount")
    var amount: Double

    @Parameter(title: "Card")
    var card: String

    /// Unset asks live; `setUpInRelayOption` (or a template that no longer
    /// exists) always hands the purchase to the app.
    @Parameter(title: "Template", optionsProvider: TemplateOptionsProvider())
    var templateChoice: String?

    @Parameter(title: "Account")
    var accountOverride: YNABAccountEntity?

    /// Only used when the resolved template's Splitwise option is "Ask Each Time".
    @Parameter(title: "Split Transaction?")
    var splitwiseRuntimeChoice: SplitwiseSplitOption?

    /// Unset falls back to the template's cached friend, then the app-wide
    /// default; with neither, the split is parked as a draft.
    @Parameter(title: "Split With")
    var splitwiseFriend: SplitwiseFriendEntity?

    @Parameter(title: "Your Share")
    var splitwiseOwnShare: Double?

    /// Lets the same purchase arriving from two automations be recognised. Blank
    /// means "wallet", keeping older automations working. Two runs sharing a
    /// source are never merged — see TransactionClaim.
    @Parameter(title: "Source", description: "Distinguishes this automation from others firing for the same purchase, e.g. \"wallet\" vs. \"bank notification\". Leave blank for the Wallet automation.")
    var source: String?

    /// For notification-driven automations, where the trigger is a bank push
    /// rather than a payment the user definitely made.
    @Parameter(title: "Require Confirmation", description: "Never add to YNAB automatically. A purchase another automation already handled is skipped as usual; anything else is saved as a draft to approve in Relay.", default: false)
    var requireConfirmation: Bool

    /// See TransactionDraftGuard — a suspended perform() can't be resumed.
    @Parameter(title: "Ensure Completion", description: "If this run is interrupted before finishing, send a notification to continue it later.", default: true)
    var ensureCompletion: Bool

    @Parameter(title: "Success Notification", description: "When this action finishes successfully, send a confirmation notification.", default: true)
    var successNotification: Bool

    // Anything requested via `$param.requestValue(...)` MUST appear here: on
    // iOS 18+ requestValue throws a connection error for a parameter that isn't
    // in parameterSummary (FB14828592, still present on iOS 26).
    // requestDisambiguation is exempt — it passes its candidates inline.
    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$amount) at \(\.$merchant) with \(\.$card) to YNAB") {
            \.$templateChoice
            \.$splitwiseRuntimeChoice
            \.$splitwiseFriend
            \.$splitwiseOwnShare
            \.$source
            \.$requireConfirmation
            \.$ensureCompletion
            \.$successNotification
        }
    }

    /// Brings Relay forward on the parked draft. Best-effort: the draft and its
    /// reminder already exist, so a declined or unavailable hand-off is
    /// swallowed rather than turned into a failed Shortcuts run.
    private func openDraftInRelay(_ draftId: UUID, merchant: String) async {
        guard systemContext.currentMode.canContinueInForeground else {
            logger.log("can't continue in foreground — leaving the reminder to it")
            return
        }
        do {
            let prompt = String(format: String(localized: "%@ needs a template. Set it up in Relay?"), merchant)
            try await continueInForeground(IntentDialog(stringLiteral: prompt))
            await MainActor.run {
                DraftNotificationRouter.shared.pendingDraftID = draftId
            }
            logger.log("continued in foreground on draft id=\(draftId.uuidString, privacy: .public)")
        } catch {
            logger.log("foreground hand-off declined or unavailable: \(String(describing: error), privacy: .public)")
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let claimSource = TransactionClaim.normalizedSource(source)
        logger.log("perform() start — merchant=\(merchant, privacy: .public) amount=\(amount, privacy: .public) card=\(card, privacy: .public) source=\(claimSource, privacy: .public)")

        // Loaded up front so the duplicate check below can resolve `card` to a
        // YNAB account id — matching on that rather than the raw string is what
        // lets Wallet's "Visa ••1234" and a bank app's "DKB Visa" be recognised
        // as the same account.
        var config = WalletTransactionConfigStore.load()

        // Settled before the claim so a draft-only sighting defers to a draft
        // already waiting for the same purchase instead of stacking behind it.
        let canFileMerchant = config.resolvedMerchantInfo(for: merchant) != nil
            || templateChoice.map { $0 != setUpInRelayOption && config.templates[$0] != nil } == true

        // Ahead of the draft guard and any network call: a purchase the other
        // automation already handled must leave behind no draft, no reminder,
        // and no API request (YNAB allows 200/hr, and a second automation
        // roughly doubles the runs).
        let claimId: UUID
        switch TransactionClaimStore.claimOrSuppress(
            TransactionClaim.Candidate(
                source: claimSource,
                destination: .ynab,
                amount: amount,
                accountId: config.cards[card],
                merchant: merchant,
                parksDraftOnly: requireConfirmation || !canFileMerchant
            )
        ) {
        case .suppressed(let suppression):
            let dialog = WalletAutomationDialog.handleSuppression(suppression, successNotification: successNotification)
            logger.log("perform() done — suppressed as duplicate of \(suppression.matched.source, privacy: .public)")
            return .result(dialog: "\(dialog)")
        case .claimed(let id):
            claimId = id
        }

        // Deliberately not gated on `ensureCompletion`: that switch rescues a
        // run that might not finish, whereas here the draft *is* the outcome,
        // so honouring it would drop the transaction.
        if requireConfirmation {
            let dialog = WalletAutomationDialog.handleAwaitingConfirmation(
                claimId,
                payload: .ynabWallet(merchant: merchant, amount: amount, card: card),
                source: claimSource
            )
            logger.log("perform() done — nothing to confirm, left a draft to approve")
            return .result(dialog: "\(dialog)")
        }

        // Committed the moment the YNAB write lands rather than at the end of
        // perform(): from then on there IS a transaction for a later duplicate
        // to collide with, even if the optional split never finishes.
        var claimResolved = false
        func commitClaim(historyEntryId: UUID?) {
            guard !claimResolved else { return }
            claimResolved = true
            WalletAutomationDialog.commitClaim(claimId, historyEntryId: historyEntryId)
        }

        // The draft the safety-net reminder currently guards — swapped for a
        // .splitwiseWallet one once YNAB is committed below, so the catch
        // handler always fails whichever half is still outstanding.
        let activeDraftId = ensureCompletion
            ? TransactionDraftGuard.begin(.ynabWallet(merchant: merchant, amount: amount, card: card))
            : nil

        // Called after every follow-up question is answered, so a slow-to-answer
        // run doesn't get a premature nudge mid-flow.
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

            var changed = false

            // The questions below use the async `requestValue` API, which
            // suspends perform() in place, rather than the deprecated throwing
            // form that re-runs it from the top — so perform() runs exactly
            // once and can't create a duplicate transaction on restart.
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
                } else if config.templates.isEmpty {
                    // Don't put a one-option question in front of the user.
                    logger.log("no merchant match and no templates yet")
                    resolvedTemplateChoice = setUpInRelayOption
                } else {
                    logger.log("no merchant match — requesting template choice")
                    let prompt = String(format: String(localized: "Which template for \"%@\"?"), merchant)
                    resolvedTemplateChoice = try await $templateChoice.requestValue(IntentDialog(stringLiteral: prompt))
                    touchDraft()
                }

                // A missing template also covers the old "Create New Template"
                // sentinel still stored in older automations, so nothing has to
                // migrate. Not gated on `ensureCompletion`, same as the
                // requireConfirmation branch above.
                guard resolvedTemplateChoice != setUpInRelayOption,
                      let template = config.templates[resolvedTemplateChoice] else {
                    let handoff = WalletAutomationDialog.handleNeedsTemplate(
                        claimId,
                        payload: .ynabWallet(merchant: merchant, amount: amount, card: card),
                        draftId: activeDraftId
                    )
                    await openDraftInRelay(handoff.draftId, merchant: merchant)
                    logger.log("perform() done — no template for merchant, left a draft to finish in Relay")
                    return .result(dialog: "\(handoff.dialog)")
                }
                logger.log("filing merchant under template=\(resolvedTemplateChoice, privacy: .public)")

                // The raw merchant string becomes the payee; cleaning it up is
                // template editing, done in Relay rather than asked here.
                if config.linkMerchantIfChanged(merchant: merchant, payeeName: merchant, templateName: resolvedTemplateChoice) {
                    changed = true
                }
                payeeName = merchant
                categoryId = template.categoryId
                splitwiseOption = template.splitwiseOption
                templateFriend = template.splitwiseFriend
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
                // The claim went in without an account (the card wasn't mapped
                // yet), so backfill it — a sighting arriving during this run's
                // remaining questions can then still be rejected on a
                // conflicting account rather than matching on amount and time.
                TransactionClaimStore.setAccountId(account.id, for: claimId)
            }

            // Persisted before committing YNAB so an interrupted split phase
            // below can't lose the resolved payee/template/card mappings.
            if changed {
                do {
                    try WalletTransactionConfigStore.save(config)
                    logger.log("config saved")
                } catch {
                    logger.error("failed to save config: \(String(describing: error), privacy: .public)")
                }
            }

            // Committed ahead of the Splitwise questions, which it never depends
            // on, so an interruption during the optional split below still
            // leaves the YNAB transaction complete.
            //
            // The shared group id folds both writes into one history entry.
            let walletGroupId = UUID()
            let milliunits = -Int((amount * Const.milliunitsPerUnit).rounded()) // outflow
            let transaction = YNABTransactionRequest(
                accountId: accountId,
                date: YNABService.todayDateString(),
                amount: milliunits,
                payeeName: payeeName,
                categoryId: categoryId,
                memo: nil,
                cleared: Const.YNAB.uncleared,
                approved: true
            )
            let formattedAmount = amount.asMoneyString
            logger.log("creating YNAB transaction: accountId=\(accountId, privacy: .public) amountMilliunits=\(milliunits, privacy: .public) payee=\(payeeName, privacy: .public) categoryId=\(categoryId ?? "nil", privacy: .public)")
            let ynabOutcome = try await PendingSync.createYNABTransaction(transaction, token: token, summary: "\(formattedAmount) at \(payeeName)", groupId: walletGroupId, merchant: merchant)
            var dialog = WalletAutomationDialog.handleYNABOutcome(ynabOutcome, formattedAmount: formattedAmount, payeeName: payeeName, categoryId: categoryId)
            logger.log("YNAB result: \(dialog, privacy: .public)")

            // Only a `.created` write has recorded a history entry to hang
            // suppressions off — a queued one records on sync, so
            // newestEntryID() would name an earlier, unrelated transaction.
            commitClaim(historyEntryId: ynabOutcome == .created ? TransactionHistoryStore.newestEntryID() : nil)

            // A template can carry a non-.never option from before Splitwise was
            // disconnected; don't ask for a friend/share that can only fail.
            let effectiveSplitwiseOption = SplitwiseAuthService.currentAccessToken != nil ? splitwiseOption : .never
            guard effectiveSplitwiseOption != .never else {
                if let activeDraftId {
                    TransactionDraftGuard.complete(activeDraftId)
                }
                if successNotification {
                    let content = WalletAutomationDialog.notificationContent(
                        isQueued: ynabOutcome == .queued,
                        formattedAmount: formattedAmount,
                        name: payeeName,
                        defaultTitle: String(localized: "Transaction Added"),
                        dialog: dialog
                    )
                    WalletCompletionNotification.postConfirmation(
                        title: content.title,
                        dialog: content.body,
                        historyEntryID: TransactionHistoryStore.newestEntryID()
                    )
                }
                logger.log("perform() done — no split")
                return .result(dialog: "\(dialog)")
            }

            // Resolved up front so it's on hand both for the split-choice
            // notification and for a background completion.
            let resolvedFriend: SplitwiseFriendEntity? = splitwiseFriend
                ?? templateFriend.map { SplitwiseFriendEntity(id: $0.id, firstName: $0.firstName, fullName: $0.fullName) }
                ?? SplitwiseDefaultFriendStore.load().map { SplitwiseFriendEntity(id: $0.id, firstName: $0.firstName, fullName: $0.fullName) }

            // Repoints the SAME draft — and so the same notification slot — at
            // the remaining split, rather than completing one and beginning
            // another: a single run must never leave two reminders able to fire.
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
                    // With YNAB already committed, an interruption here can be
                    // answered straight from the reminder, so arm its split
                    // actions for the duration of the question.
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
                            prompt = String(localized: "Split this transaction with Splitwise?")
                        } else {
                            prompt = String(format: String(localized: "Split this %@ transaction with Splitwise?"), splitDescription)
                        }
                        return try await $splitwiseRuntimeChoice.requestValue(IntentDialog(stringLiteral: prompt))
                    }
                    touchDraft()
                }
            }

            guard splitwiseAction != .never else {
                if let activeDraftId {
                    TransactionDraftGuard.complete(activeDraftId)
                }
                if successNotification {
                    let content = WalletAutomationDialog.notificationContent(
                        isQueued: ynabOutcome == .queued,
                        formattedAmount: formattedAmount,
                        name: payeeName,
                        defaultTitle: String(localized: "Transaction Added"),
                        dialog: dialog
                    )
                    WalletCompletionNotification.postConfirmation(
                        title: content.title,
                        dialog: content.body,
                        historyEntryID: TransactionHistoryStore.newestEntryID()
                    )
                }
                logger.log("perform() done — not split")
                return .result(dialog: "\(dialog)")
            }

            guard let friend = resolvedFriend else {
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
            let split = await WalletAutomationDialog.splitDialogFragment(amount: amount, description: payeeName, friend: friend, ownShare: ownShare, groupId: walletGroupId, merchant: merchant)
            logger.log("Splitwise split result: \(split.fragment, privacy: .public)")
            dialog += split.fragment

            if let activeDraftId {
                TransactionDraftGuard.complete(activeDraftId)
            }

            if successNotification {
                let content = WalletAutomationDialog.notificationContent(
                    isQueued: ynabOutcome == .queued || split.isQueued,
                    formattedAmount: formattedAmount,
                    name: payeeName,
                    defaultTitle: String(localized: "Split Added"),
                    dialog: dialog
                )
                WalletCompletionNotification.postConfirmation(
                    title: content.title,
                    dialog: content.body,
                    historyEntryID: TransactionHistoryStore.newestEntryID()
                )
            }

            logger.log("perform() done")
            return .result(dialog: "\(dialog)")
        } catch {
            // Nudge the user right away rather than waiting out the quiet-period
            // window — the run is ending with something still unfinished.
            if let activeDraftId {
                await TransactionDraftGuard.fail(activeDraftId)
            }
            // Only reached when the YNAB write never landed: this run wrote
            // nothing, so it must stop shadowing the other automation.
            if !claimResolved {
                TransactionClaimStore.abandon(claimId)
            }
            throw error
        }
    }
}
