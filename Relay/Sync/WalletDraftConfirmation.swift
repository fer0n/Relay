//
//  WalletDraftConfirmation.swift
//  Relay
//
//  Answers "Add" on a "Confirm Transaction" reminder (see
//  WalletConfirmNotification) in the background, without opening the app.
//
//  The draft was left by an automation that returned before resolving anything,
//  so unlike WalletDraftCompletion — which works from a context the interrupted
//  run had already resolved — this has to resolve it here, strictly from what's
//  saved. Confirming from a banner must never guess, so the moment something
//  would have to be *asked* it stops: either handing the question on as its own
//  reminder, or sending the user into Relay where the form can ask properly.
//

import Foundation
import os

private nonisolated let logger = Logger(subsystem: Const.loggerSubsystem, category: "WalletDraftConfirmation")

nonisolated enum WalletDraftConfirmation {
    enum Result {
        /// Everything's in. `title`/`dialog` are ready to show as-is.
case completed(title: String, dialog: String)
        /// The transaction landed but the split needs an answer, and its follow-up
        /// reminder is already posted — so the caller mustn't add one of its own.
        case followUpPosted
        /// Nothing written; the draft is intact and has to be finished in the app.
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
        // Both are questions the intent would have asked, so hand over to the app
        // rather than inventing a payee or picking an account.
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

        // A lone YNAB transaction needs no group id to hang a split off.
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
                groupId: groupId,
                merchant: merchant
            )
        } catch {
            // Leave the draft so the app can retry with the error in front of the
            // user.
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
            // Fully determined, so just do it as the automation would have.
            dialog += await WalletAutomationDialog.splitDialogFragment(
                amount: amount,
                description: info.payeeName,
                friend: friend!,
                ownShare: nil,
                groupId: groupId,
                merchant: merchant
            ).fragment
        case .always, .manual, .ask:
            // YNAB is already in, so hand the remainder off the same way an
            // interrupted run does: repoint this draft at the split and let the
            // reminder carry the quick replies.
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

    /// Here the split *is* the transaction, so "Add" can only finish on its own
    /// when the template already says how to split and with whom.
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
            // Includes "never", which pressing Add has just overridden — so the
            // honest reading is "add it, but you still have to say how".
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

    /// Approving the draft counts as the claim that parked it finally writing, so
    /// the other automation turning up late in the window is suppressed rather
    /// than adding the purchase a second time.
    private static func commitClaim(for draft: TransactionDraft, wroteEntry: Bool) {
        guard let claimId = TransactionClaimStore.claimId(forDraft: draft.id) else { return }
        WalletAutomationDialog.commitClaim(claimId, historyEntryId: wroteEntry ? TransactionHistoryStore.newestEntryID() : nil)
    }

    /// The same handover an interrupted wallet run does, and the reason the split
    /// actions can finish it later without re-resolving any of this context.
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
