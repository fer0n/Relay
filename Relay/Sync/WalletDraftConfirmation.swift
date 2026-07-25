//
//  WalletDraftConfirmation.swift
//  Relay
//
//  Answers "Add" on a "Confirm Transaction" reminder (see
//  WalletConfirmNotification) in the background, without opening the app.
//
//  The draft it acts on was left by an automation with "Require
//  Confirmation" set, which returned before resolving anything — so unlike
//  WalletDraftCompletion, which works purely from a context the interrupted
//  run had already resolved, this has to do the resolution itself. It does
//  that strictly from what's already saved: the merchant's template and the
//  card's account mapping. Confirming from a banner must never guess, so the
//  moment something would have to be *asked* it stops — either handing the
//  question on as its own reminder (an outstanding split, which the existing
//  quick replies already answer) or, where there's no reminder shaped like
//  the question — an unknown merchant, an unmapped card — sending the user
//  into Relay, where the draft is still sitting and the form can ask
//  properly.
//
//  Note the Splitwise-primary path mostly doesn't arrive here at all: an
//  "ask each time" merchant never gets an Add/Discard reminder in the first
//  place, because the split question doubles as the confirmation (see
//  WalletAutomationDialog.handleAwaitingSplitwiseConfirmation).
//

import Foundation
import os

private let logger = Logger(subsystem: Const.loggerSubsystem, category: "WalletDraftConfirmation")

nonisolated enum WalletDraftConfirmation {
    enum Result {
        /// Everything's in, nothing left to ask. `title`/`dialog` are ready
        /// to show as-is in a confirmation notification.
        case completed(title: String, dialog: String)
        /// The transaction landed, but the split still needs an answer — a
        /// follow-up reminder for it has already been posted, so the caller
        /// shouldn't add one of its own.
        case followUpPosted
        /// Nothing was written; the draft is intact and the user has to
        /// finish it in the app.
        case needsApp
    }

    static func confirm(_ draft: TransactionDraft) async -> Result {
        switch draft.payload {
        case .ynabWallet(let merchant, let amount, let card):
            await confirmYNAB(draft: draft, merchant: merchant, amount: amount, card: card)
        case .splitwiseWallet(let merchant, let amount, _):
            await confirmSplitwise(draft: draft, merchant: merchant, amount: amount)
        }
    }

    // MARK: - YNAB

    private static func confirmYNAB(draft: TransactionDraft, merchant: String, amount: Double, card: String) async -> Result {
        let config = WalletTransactionConfigStore.load()
        // Both of these are questions the intent would have asked. Without
        // saved answers there's nothing to confirm against, so hand over to
        // the app rather than inventing a payee or picking an account.
        guard let info = config.resolvedMerchantInfo(for: merchant) else {
            logger.log("confirm: merchant not mapped — needs app")
            return .needsApp
        }
        guard let accountId = config.cards[card] else {
            logger.log("confirm: card not mapped — needs app")
            return .needsApp
        }
        guard let token = await YNABAuthService.validAccessToken() else {
            logger.error("confirm: no YNAB access token — needs app")
            return .needsApp
        }

        let template = config.templates[info.templateName]
        // A template can carry a split setting from before Splitwise was
        // disconnected — same treatment as the intents give it.
        let splitOption = SplitwiseAuthService.currentAccessToken != nil ? (template?.splitwiseOption ?? .never) : .never
        let friend = WalletAutomationDialog.friendWithoutAsking(template: template)

        // Only worth grouping when a split is actually going to follow; a
        // lone YNAB transaction doesn't need a group id to hang one off.
        let groupId = splitOption == .never ? nil : UUID()
        let formattedAmount = amount.asMoneyString
        let transaction = YNABTransactionRequest(
            accountId: accountId,
            date: YNABService.todayDateString(),
            amount: -Int((amount * Const.milliunitsPerUnit).rounded()), // outflow
            payeeName: info.payeeName,
            categoryId: template?.categoryId,
            memo: nil,
            cleared: Const.YNAB.uncleared,
            approved: true
        )

        let outcome: PendingSyncOutcome
        do {
            outcome = try await PendingSync.createYNABTransaction(
                transaction,
                token: token,
                summary: "\(formattedAmount) at \(info.payeeName)",
                groupId: groupId
            )
        } catch {
            // A real API failure — leave the draft so the app can retry it
            // with the error in front of the user.
            logger.error("confirm: YNAB write failed: \(String(describing: error), privacy: .public)")
            return .needsApp
        }
        var dialog = WalletAutomationDialog.handleYNABOutcome(
            outcome,
            formattedAmount: formattedAmount,
            payeeName: info.payeeName,
            categoryId: template?.categoryId
        )
        commitClaim(for: draft, wroteEntry: outcome == .created)

        switch splitOption {
        case .never:
            break
        case .always where friend != nil:
            // Fully determined — no question to put to the user, so just do
            // it, exactly as the automation would have.
            dialog += await WalletAutomationDialog.splitDialogFragment(
                amount: amount,
                description: info.payeeName,
                friend: friend!,
                ownShare: nil,
                groupId: groupId
            ).fragment
        case .always, .manual, .ask:
            // The split still needs an answer (which way to split, how much,
            // or who with). YNAB is already in, so hand the remainder off the
            // same way an interrupted run does: repoint this draft at the
            // split and let the reminder carry the quick replies.
            handOffSplit(draft: draft, merchant: merchant, amount: amount, description: info.payeeName, friend: friend)
            logger.log("confirm: YNAB in, split still open — posted follow-up")
            return .followUpPosted
        }

        TransactionDraftGuard.complete(draft.id)
        logger.log("confirm: completed in background — \(dialog, privacy: .public)")
        let content = WalletAutomationDialog.notificationContent(
            isQueued: outcome == .queued,
            formattedAmount: formattedAmount,
            name: info.payeeName,
            defaultTitle: String(localized: "Transaction Added"),
            dialog: dialog
        )
        return .completed(title: content.title, dialog: content.body)
    }

    // MARK: - Splitwise

    /// On this path the split *is* the transaction, so "Add" can only finish
    /// on its own when the template already says how to split and with whom.
    /// Anything less becomes the split-choice question rather than a guess.
    private static func confirmSplitwise(draft: TransactionDraft, merchant: String, amount: Double) async -> Result {
        guard SplitwiseAuthService.currentAccessToken != nil else {
            logger.error("confirm: no Splitwise access token — needs app")
            return .needsApp
        }
        let config = WalletTransactionConfigStore.load()
        let info = config.resolvedMerchantInfo(for: merchant)
        let description = info?.payeeName ?? merchant
        let template = info.flatMap { config.templates[$0.templateName] }
        let friend = WalletAutomationDialog.friendWithoutAsking(template: template)

        guard let friend else {
            logger.log("confirm: no Splitwise friend resolvable — needs app")
            return .needsApp
        }

        guard template?.splitwiseOption == .always else {
            // "Ask each time", "manual", or a merchant with no template at
            // all — and also "never", which the user has just overridden by
            // pressing Add, so the honest reading is "add it, but you still
            // have to say how".
            TransactionDraftGuard.askSplitChoiceViaNotification(
                draft.id,
                context: TransactionDraft.PendingSplitContext(
                    description: description,
                    friendId: friend.id,
                    friendFirstName: friend.firstName,
                    friendFullName: friend.fullName
                )
            )
            logger.log("confirm: split choice still open — posted follow-up")
            return .followUpPosted
        }

        let formattedAmount = amount.asMoneyString
        do {
            let outcome = try await SplitwiseExpenseHelper.addExpense(
                amount: amount,
                description: description,
                friend: friend,
                ownShare: nil,
                merchant: merchant
            )
            let dialog = WalletAutomationDialog.splitwiseWalletDialog(
                outcome: outcome,
                formattedAmount: formattedAmount,
                description: description
            )
            let isQueued: Bool = if case .queued = outcome { true } else { false }
            commitClaim(for: draft, wroteEntry: !isQueued)
            TransactionDraftGuard.complete(draft.id)
            logger.log("confirm: completed in background — \(dialog, privacy: .public)")
            let content = WalletAutomationDialog.notificationContent(
                isQueued: isQueued,
                formattedAmount: formattedAmount,
                name: description,
                defaultTitle: String(localized: "Expense Added"),
                dialog: dialog
            )
            return .completed(title: content.title, dialog: content.body)
        } catch {
            logger.error("confirm: Splitwise write failed: \(String(describing: error), privacy: .public)")
            return .needsApp
        }
    }

    // MARK: - Shared

    /// Approving the draft is the claim that parked it finally writing its
    /// transaction — so record it as committed, and the other automation
    /// turning up late in the match window gets suppressed instead of adding
    /// the purchase a second time.
    private static func commitClaim(for draft: TransactionDraft, wroteEntry: Bool) {
        guard let claimId = TransactionClaimStore.claimId(forDraft: draft.id) else { return }
        WalletAutomationDialog.commitClaim(claimId, historyEntryId: wroteEntry ? TransactionHistoryStore.newestEntryID() : nil)
    }

    /// Repoints a confirmed YNAB draft at the split that's still outstanding
    /// and arms the quick replies on its reminder — the same handover an
    /// interrupted wallet run does, and the reason the split actions can
    /// finish it later without any of this context being re-resolved.
    private static func handOffSplit(
        draft: TransactionDraft,
        merchant: String,
        amount: Double,
        description: String,
        friend: SplitwiseFriendEntity?
    ) {
        TransactionDraftGuard.transition(draft.id, to: .splitwiseWallet(merchant: merchant, amount: amount))
        TransactionDraftGuard.askSplitChoiceViaNotification(
            draft.id,
            context: TransactionDraft.PendingSplitContext(
                description: description,
                friendId: friend?.id,
                friendFirstName: friend?.firstName,
                friendFullName: friend?.fullName
            )
        )
    }
}
