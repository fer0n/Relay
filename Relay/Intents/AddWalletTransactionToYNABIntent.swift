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
//  Setting a template up is deliberately not done from here. A merchant
//  that's already mapped runs straight through; an unknown one is asked the
//  single question a Shortcuts prompt is any good at — "which template?" —
//  and picking an existing one files the merchant under it right away. Every
//  other setup question the original Shortcut chained together (a new
//  template's name, its category, its Splitwise rule, a clean payee name,
//  auto-match patterns) is a form's worth of input, and Relay already has
//  that form: the run parks the purchase as a draft, posts a reminder, and
//  ContinueWalletTransactionView finishes it. That's what keeps this intent's
//  parameter list down to the things an automation actually wants to pin.
//
//  A merchant filed here starts out with the raw merchant string as its
//  payee; renaming it (and adding auto-match rules so sibling merchants
//  reuse the name) happens in Relay's Templates screen, exactly as it does
//  for AddWalletTransactionToSplitwiseIntent.
//
//  Splitwise still mirrors the original: "Use Splitwise?" (always/manual/
//  ask/never — see SplitwiseTemplateOption) is a template setting, edited
//  alongside the category in Relay. "Ask" keeps prompting live on every
//  transaction for that merchant via `splitwiseRuntimeChoice`, mirroring the
//  original's Ja/Manuell/Nein menu.
//
//  The Splitwise friend to split with is a separate question from whether to
//  split at all, and this intent never asks it: the `splitwiseFriend`
//  parameter wins, then the resolved template's own cached friend (e.g.
//  configured in Templates, or shared with AddWalletTransactionToSplitwise
//  Intent's template of the same name), then the app-wide default friend.
//  With none of those the split is parked as a draft to finish in Relay —
//  and an automation that would rather be asked in the moment sets
//  Shortcuts' native "Ask Each Time" on "Split With", so there's no
//  fallback parameter to model (same argument as SplitwiseSplitOption's).
//

import AppIntents
import os

private nonisolated let logger = Logger(subsystem: Const.loggerSubsystem, category: "WalletTransaction")

struct AddWalletTransactionToYNABIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Wallet Transaction to YNAB"
    static let description = IntentDescription(
        "Adds a YNAB transaction from a Wallet transaction, remembering payee/category/account choices for next time."
    )

    // Runs in the background like any wallet automation should — `.dynamic`
    // only adds the *option* of asking to come forward mid-run, which this
    // uses in exactly one place: handing an unmapped merchant over to the
    // in-app form (see openDraftInRelay). Not `.foreground(.immediate)` like
    // ImportSplitwiseFileIntent, whose whole purpose is the screen it opens.
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

    @Parameter(title: "Merchant")
    var merchant: String

    @Parameter(title: "Amount")
    var amount: Double

    @Parameter(title: "Card")
    var card: String

    /// Which template an unmapped merchant is filed under, so an automation
    /// that only ever sees one kind of purchase never has to be asked. Left
    /// unset, the run asks live; set to `setUpInRelayOption` (or to a template
    /// that no longer exists) the purchase is always handed to the app.
    @Parameter(title: "Template", optionsProvider: TemplateOptionsProvider())
    var templateChoice: String?

    @Parameter(title: "Account")
    var accountOverride: YNABAccountEntity?

    /// Only used when the resolved template's Splitwise option is "Ask
    /// Each Time" — the live per-transaction equivalent of the original's
    /// Ja/Manuell/Nein menu.
    @Parameter(title: "Split Transaction?")
    var splitwiseRuntimeChoice: SplitwiseSplitOption?

    /// Who to split with, when this automation's transactions always go to
    /// the same person. Left unset, the resolved template's cached friend or
    /// the app-wide default (`SplitwiseDefaultFriendStore`) is used; set
    /// Shortcuts' own "Ask Each Time" on it to be asked instead.
    @Parameter(title: "Split With")
    var splitwiseFriend: SplitwiseFriendEntity?

    @Parameter(title: "Your Share")
    var splitwiseOwnShare: Double?

    /// Which automation this run came from, so the same purchase arriving
    /// twice can be recognised — the Wallet "Transaction" automation and an
    /// iOS 27 notification automation on the bank app's push both fire for
    /// the same in-person payment. Blank means "wallet", so automations
    /// built before this parameter existed keep working untouched. Two runs
    /// sharing a source are never merged (see TransactionClaim).
    @Parameter(title: "Source", description: "Distinguishes this automation from others firing for the same purchase, e.g. \"wallet\" vs. \"bank notification\". Leave blank for the Wallet automation.")
    var source: String?

    /// Turns this automation into a read-only one: it can confirm a purchase
    /// another automation already handled, but it can never add a transaction
    /// by itself — an unrecognised purchase becomes a draft to approve
    /// instead. Intended for a notification-driven automation, where the
    /// trigger is a push from the bank app rather than a payment the user
    /// definitely made: without this, anything the notification filter lets
    /// through lands in YNAB unseen.
    @Parameter(title: "Require Confirmation", description: "Never add to YNAB automatically. A purchase another automation already handled is skipped as usual; anything else is saved as a draft to approve in Relay.", default: false)
    var requireConfirmation: Bool

    /// See TransactionDraftGuard: if this run gets interrupted (a follow-up
    /// question dismissed/timed out, the process killed by a screen lock)
    /// before the transaction is actually created, a local notification
    /// nudges the user to go finish it — since there's no way to resume a
    /// suspended perform() call.
    @Parameter(title: "Ensure Completion", description: "If this run is interrupted before finishing, send a notification to continue it later.", default: true)
    var ensureCompletion: Bool

    @Parameter(title: "Success Notification", description: "When this action finishes successfully, send a confirmation notification.", default: true)
    var successNotification: Bool

    // Parameters requested at runtime via `$param.requestValue(...)` MUST
    // appear here: on iOS 18+ requestValue throws a connection error for a
    // parameter that isn't in parameterSummary (FB14828592, confirmed still
    // present on iOS 26). That's `templateChoice`, `splitwiseRuntimeChoice`
    // and `splitwiseOwnShare` — the three questions this intent still asks
    // live, now that template setup has moved into the app. `accountOverride`
    // is instead resolved with requestDisambiguation, which passes its
    // candidate list inline and so works while omitted here. `splitwiseFriend`
    // is never requested at runtime either, but a parameter left out of the
    // summary isn't rendered in Shortcuts at all — and being settable (by hand,
    // or via Shortcuts' native "Ask Each Time") is the entire point of it.
    // `source` is listed for the same reason. `card` is folded into the main
    // sentence since it's required. Shortcuts collapses the rest under "Show
    // More" rather than showing them inline.
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

    /// Asks iOS to bring Relay forward on the draft that was just parked, so
    /// a merchant that needs setting up lands on the form instead of leaving
    /// the user to find the reminder. Best-effort by design:
    ///
    /// - `canContinueInForeground` is false in the contexts where this can't
    ///   work at all (a locked device, which is common enough — the Wallet
    ///   automation fires seconds after a payment, phone already pocketed).
    /// - iOS puts its own confirmation in front of the switch, so nothing
    ///   yanks the user out of what they were doing without a tap.
    /// - Any failure (declined, or refused outright) is swallowed rather than
    ///   thrown: the draft and its reminder already exist, and turning a
    ///   declined hand-off into a failed Shortcuts run would look like the
    ///   transaction was lost.
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

        // Loaded up front so the duplicate check below can resolve `card` to
        // a YNAB account id — matching on that rather than the raw string is
        // what lets Wallet's "Visa ••1234" and a bank app's "DKB Visa" be
        // recognised as the same account. Reused for the rest of perform()
        // rather than re-read; nothing in between touches it.
        var config = WalletTransactionConfigStore.load()

        // Whether this run could file the transaction at all, or can only ever
        // park a draft: an unmapped merchant has to be set up in the app,
        // unless the automation pins a Template that already exists. Settled
        // here, before the claim, so such a sighting defers to a draft that's
        // already waiting for the same purchase instead of stacking a second
        // one behind it (see TransactionClaim.Candidate.parksDraftOnly).
        let canFileMerchant = config.resolvedMerchantInfo(for: merchant) != nil
            || templateChoice.map { $0 != setUpInRelayOption && config.templates[$0] != nil } == true

        // Ahead of the draft guard and of any network call: a purchase the
        // other automation already handled must leave behind no draft, no
        // reminder, and no API request (which matters against YNAB's 200/hr
        // cap, since wiring up a second automation roughly doubles the runs).
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

        // Nothing to confirm — so on a confirm-only automation this purchase
        // stops here as a draft, no questions asked and no YNAB call made.
        // Deliberately not gated on `ensureCompletion`: that switch is about
        // rescuing a run that might not finish, whereas here the draft *is*
        // the finished outcome and turning it off would silently drop the
        // transaction altogether.
        if requireConfirmation {
            let dialog = WalletAutomationDialog.handleAwaitingConfirmation(
                claimId,
                payload: .ynabWallet(merchant: merchant, amount: amount, card: card),
                source: claimSource
            )
            logger.log("perform() done — nothing to confirm, left a draft to approve")
            return .result(dialog: "\(dialog)")
        }

        // Resolves the claim exactly once, whichever way the run ends.
        // Committed the moment the YNAB write lands rather than at the end
        // of perform(): from that point there IS a transaction for a later
        // duplicate to collide with, even if the optional split below never
        // finishes. Abandoned in the catch, so a run that wrote nothing
        // stops shadowing the other automation — which is precisely the
        // safety net that case needs.
        var claimResolved = false
        func commitClaim(historyEntryId: UUID?) {
            guard !claimResolved else { return }
            claimResolved = true
            WalletAutomationDialog.commitClaim(claimId, historyEntryId: historyEntryId)
        }

        // The draft the safety-net reminder currently guards. Starts as the
        // .ynabWallet draft (the whole transaction is unfinished); once YNAB
        // is committed below it's swapped for a .splitwiseWallet draft (only
        // the optional split remains), and the catch handler always fails
        // whichever one is active.
        let activeDraftId = ensureCompletion
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
                } else if config.templates.isEmpty {
                    // Nothing to choose between — the only option the picker
                    // could offer is the "set it up in Relay" sentinel, so
                    // don't put a one-option question in front of the user.
                    logger.log("no merchant match and no templates yet")
                    resolvedTemplateChoice = setUpInRelayOption
                } else {
                    logger.log("no merchant match — requesting template choice")
                    let prompt = String(format: String(localized: "Which template for \"%@\"?"), merchant)
                    resolvedTemplateChoice = try await $templateChoice.requestValue(IntentDialog(stringLiteral: prompt))
                    touchDraft()
                }

                // Either the user asked for it to be set up in Relay, or the
                // pinned Template names one that no longer exists — which also
                // covers the old "Create New Template" sentinel still stored in
                // an automation built before this, so nothing has to migrate.
                // Both mean this run can't file the merchant on its own: park
                // the purchase as a draft and let Relay's form ask the rest.
                // Deliberately not gated on `ensureCompletion`, for the same
                // reason as the requireConfirmation branch above — the draft
                // *is* the outcome here, not a rescue for a run that might
                // still finish, and turning it off would drop the transaction.
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

                // The raw merchant string becomes the payee. Cleaning that up —
                // and adding the auto-match rule that makes sibling merchants
                // reuse the tidy name — is template editing, done in Relay
                // rather than asked here through a text prompt.
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
                // The card wasn't mapped when the claim was written, so it
                // went in without an account. Backfill it now that the user
                // has picked one, so a sighting arriving during this run's
                // remaining questions can still be rejected on a conflicting
                // account rather than matching on amount and time alone.
                TransactionClaimStore.setAccountId(account.id, for: claimId)
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
            //
            // Shared by the YNAB write and any Splitwise split below so the
            // two fold into one combined history entry rather than two rows.
            let walletGroupId = UUID()
            let milliunits = -Int((amount * Const.milliunitsPerUnit).rounded()) // outflow: negative milliunits
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
            let ynabOutcome = try await PendingSync.createYNABTransaction(transaction, token: token, summary: "\(formattedAmount) at \(payeeName)", groupId: walletGroupId)
            var dialog = WalletAutomationDialog.handleYNABOutcome(ynabOutcome, formattedAmount: formattedAmount, payeeName: payeeName, categoryId: categoryId)
            logger.log("YNAB result: \(dialog, privacy: .public)")

            // There's a transaction now (or a queued one that will sync), so
            // the claim stands regardless of how the split below goes. Only
            // a `.created` write has recorded a history entry to hang
            // suppressions off — a queued one records on sync, so
            // newestEntryID() would name some earlier, unrelated transaction.
            commitClaim(historyEntryId: ynabOutcome == .created ? TransactionHistoryStore.newestEntryID() : nil)

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

            // Splitwise side-split. Repoint the SAME draft — and so the same
            // notification slot — from the now-committed YNAB half to the
            // remaining split, rather than completing one draft and beginning
            // another: a single run must never leave two reminders (ynab +
            // splitwise) able to fire at once. The result is a recoverable
            // Splitwise-only reminder (YNAB is already done), not a YNAB re-do.
            // Resolve the friend up front, so it's on hand both for the
            // split-choice notification and for a background completion. Never
            // asked here: the parameter wins, then the template's cached
            // friend, then the app-wide default — and with none of those the
            // split is parked below for Relay to finish.
            let resolvedFriend: SplitwiseFriendEntity? = splitwiseFriend
                ?? templateFriend.map { SplitwiseFriendEntity(id: $0.id, firstName: $0.firstName, fullName: $0.fullName) }
                ?? SplitwiseDefaultFriendStore.load().map { SplitwiseFriendEntity(id: $0.id, firstName: $0.firstName, fullName: $0.fullName) }

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
                // Chose not to split — the YNAB transaction stands alone.
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
                // Nothing configured to split with — leave the Splitwise-only
                // draft and nudge the user to finish it in Relay (which
                // resolves the merchant back to this same template and just
                // needs a friend picked). An automation that would rather be
                // asked in the moment can set Shortcuts' own "Ask Each Time"
                // on "Split With", which needs no parameter here.
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
            let split = await WalletAutomationDialog.splitDialogFragment(amount: amount, description: payeeName, friend: friend, ownShare: ownShare, groupId: walletGroupId)
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
            // The run is ending without finishing whatever's still active —
            // the YNAB write, or the Splitwise split after it — so nudge the
            // user right away rather than waiting out the quiet-period window.
            if let activeDraftId {
                await TransactionDraftGuard.fail(activeDraftId)
            }
            // No-op once the YNAB write has landed (the claim is already
            // committed and the failure is only the split's); otherwise this
            // run wrote nothing, so it must stop shadowing the other
            // automation — which is exactly the case that safety net exists
            // for.
            if !claimResolved {
                TransactionClaimStore.abandon(claimId)
            }
            throw error
        }
    }
}
