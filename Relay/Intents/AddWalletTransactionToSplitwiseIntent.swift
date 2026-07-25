//
//  AddWalletTransactionToSplitwiseIntent.swift
//  Relay
//
//  Sibling to AddWalletTransactionToYNABIntent for a card/account used
//  purely for shared expenses: wired as the action of a Shortcuts
//  "Transaction" Personal Automation (receiving Merchant/Amount magic
//  variables), but creates a Splitwise expense directly — no YNAB
//  transaction at all. Backed by the same WalletTransactionConfigStore the
//  YNAB intent uses, so a template edited in-app works for both.
//
//  Unlike the YNAB intent — where a template is worth building up front
//  (category, account, split mode) — a Splitwise expense only needs a memo
//  + amount + split yes/no, so this intent never asks the user to set a
//  template up. An unknown merchant is auto-filed under the default
//  Splitwise template (WalletTransactionConfig.ensureSplitwiseDefaultTemplate,
//  split option `.ask`), its description defaults to the merchant name, and
//  the only live question is the split yes/no. Customizing — renaming the
//  description, a second "Don't Split" template, moving merchants, auto-match
//  rules — is all done later in Relay's Templates screen, not here.
//
//  The friend is asked once (when neither the template nor the app-wide
//  default friend supplies one) and written back onto the template, fixing
//  it for next time rather than re-asking.
//
//  Built entirely with the async requestValue/requestDisambiguation style
//  (perform() never restarts, so there's no duplicate-expense risk from a
//  restart). requestValue params must stay listed in parameterSummary —
//  on iOS 18+ it throws a connection error otherwise (see the equivalent
//  note in AddWalletTransactionToYNABIntent.swift) — while the
//  requestDisambiguation param (friendOverride) is resolved with its
//  candidates passed inline, so it can stay hidden.
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

    /// Which automation this run came from — see the equivalent parameter
    /// on AddWalletTransactionToYNABIntent. Blank means "wallet", so
    /// automations built before this existed keep working untouched.
    @Parameter(title: "Source", description: "Distinguishes this automation from others firing for the same purchase, e.g. \"wallet\" vs. \"bank notification\". Leave blank for the Wallet automation.")
    var source: String?

    @Parameter(title: "Split With")
    var friendOverride: SplitwiseFriendEntity?

    @Parameter(title: "If Split With Isn't Set", default: .defaultFriend)
    var splitwiseFriendFallback: SplitwiseFriendFallback

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
            \.$source
            \.$friendOverride
            \.$splitwiseFriendFallback
            \.$splitwiseOwnShare
            \.$splitwiseRuntimeChoice
            \.$ensureCompletion
            \.$successNotification
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let claimSource = TransactionClaim.normalizedSource(source)
        logger.log("perform() start — merchant=\(merchant, privacy: .public) amount=\(amount, privacy: .public) source=\(claimSource, privacy: .public)")

        // Ahead of the draft guard and of any network call, so a purchase
        // the other automation already handled leaves no draft, no reminder
        // and no API request behind. No account id to match on here — this
        // intent has no card parameter — which `matches` treats as "no
        // signal" rather than as agreement, leaving amount and time to carry
        // it.
        let claimId: UUID
        switch TransactionClaimStore.claimOrSuppress(
            TransactionClaim.Candidate(
                source: claimSource,
                destination: .splitwise,
                amount: amount,
                accountId: nil,
                merchant: merchant
            )
        ) {
        case .suppressed(let suppression):
            let dialog = WalletAutomationDialog.handleSuppression(suppression, successNotification: successNotification)
            logger.log("perform() done — suppressed as duplicate of \(suppression.matched.source, privacy: .public)")
            return .result(dialog: "\(dialog)")
        case .claimed(let id):
            claimId = id
        }

        // Resolves the claim exactly once, whichever way the run ends.
        // Unlike the YNAB intent there's nothing committed ahead of the
        // split — the expense *is* the transaction — so this only fires at
        // the very end, either on a created/queued expense or on a
        // deliberate "Don't Split".
        var claimResolved = false
        func commitClaim(historyEntryId: UUID?) {
            guard !claimResolved else { return }
            claimResolved = true
            let parked = TransactionClaimStore.commit(claimId, historyEntryId: historyEntryId)
            if let historyEntryId {
                TransactionHistoryStore.recordSuppressions(parked, on: historyEntryId)
            }
        }

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
        func resolveFriend(existing: WalletTransactionConfig.CachedFriend?, dialog: IntentDialog) async throws -> WalletTransactionConfig.CachedFriend {
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
                // Backfill the friend if the template didn't have one yet
                // (e.g. it was only ever used from the YNAB intent) so future
                // runs skip asking — same rule as a freshly-created template
                // below, shared via cacheSplitwiseFriendIfMissing.
                var updated = template ?? WalletTransactionConfig.Template()
                if updated.cacheSplitwiseFriendIfMissing(resolved) {
                    config.templates[info.templateName] = updated
                    changed = true
                }
            } else {
                // No stored mapping for this merchant: auto-file it under the
                // default Splitwise template rather than walking the user
                // through template/description/auto-match/split-option setup.
                // The description just defaults to the merchant name (rename
                // it later in Templates), and the split question is still
                // asked because the default template's option is `.ask`.
                // Customization (a second "Don't Split" template, moving
                // merchants over, auto-match rules) all happens in-app later.
                let templateName = config.ensureSplitwiseDefaultTemplate()
                let template = config.templates[templateName]

                let resolvedFriend = try await resolveFriend(
                    existing: template?.splitwiseFriend,
                    dialog: IntentDialog(stringLiteral: String(format: String(localized: "Split %@ expenses with which friend?"), templateName))
                )

                // File the merchant under the default template and pin the
                // resolved friend onto it (unless it already had one) so
                // future merchants filed here skip the ask. Same shared path
                // the in-app Splitwise submit uses; `changed` stays true
                // regardless since ensureSplitwiseDefaultTemplate may have
                // just created the template. Leaving "Split With" as Default
                // in Templates resets it to follow the app-wide default again.
                _ = config.recordSplitwiseMerchantLink(
                    merchant: merchant,
                    payeeName: merchant,
                    templateName: templateName,
                    friend: resolvedFriend
                )
                expenseDescription = merchant
                friendId = resolvedFriend.id
                friendFirstName = resolvedFriend.firstName
                friendFullName = resolvedFriend.fullName
                splitOption = config.templates[templateName]?.splitwiseOption ?? .never
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
                // Nothing written, but the purchase *has* been decided on —
                // commit rather than abandon so the other automation doesn't
                // come back and ask the same split question a second time.
                // No history entry exists to hang suppressions off, hence nil.
                commitClaim(historyEntryId: nil)
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
                    ownShare: (splitwiseAction == .manual) ? resolvedOwnShare : nil,
                    merchant: merchant
                )
                if let draftId {
                    TransactionDraftGuard.complete(draftId)
                }
                let isQueued: Bool = if case .queued = outcome { true } else { false }
                // A queued expense records its history entry only once it
                // syncs, so newestEntryID() would name an earlier, unrelated
                // one — commit without an entry to annotate in that case.
                commitClaim(historyEntryId: isQueued ? nil : TransactionHistoryStore.newestEntryID())
                let dialog = WalletAutomationDialog.splitwiseWalletDialog(outcome: outcome, formattedAmount: formattedAmount, description: expenseDescription)
                if successNotification {
                    let content = WalletAutomationDialog.notificationContent(
                        isQueued: isQueued,
                        formattedAmount: formattedAmount,
                        name: expenseDescription,
                        defaultTitle: String(localized: "Split Added"),
                        dialog: dialog
                    )
                    WalletCompletionNotification.postConfirmation(
                        title: content.title,
                        dialog: content.body,
                        historyEntryID: TransactionHistoryStore.newestEntryID()
                    )
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
            // Nothing was written, so this run must stop shadowing the other
            // automation — that second sighting is the safety net for
            // exactly this failure.
            if !claimResolved {
                TransactionClaimStore.abandon(claimId)
            }
            throw error
        }
    }
}
