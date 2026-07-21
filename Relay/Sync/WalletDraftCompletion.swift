//
//  WalletDraftCompletion.swift
//  Relay
//
//  Answers the "split with Splitwise?" question from a notification action,
//  in the background, without opening the app. Always does just the Splitwise
//  half, via the same SplitwiseExpenseHelper / WalletAutomationDialog path the
//  intents and ContinueWalletTransactionView use. Both wallet
//  automations arm this: for the YNAB one the YNAB transaction is already
//  committed by the time the split is asked, so this finishes an optional
//  side-split; for the standalone Splitwise one the expense *is* the split,
//  so this creates the whole transaction (and Don't Split resolves it to
//  nothing, matching the intent's own skip).
//
//  Only called for a `.splitwiseWallet` draft carrying a PendingSplitContext,
//  i.e. one armed at the split question with its description + friend already
//  resolved. Everything comes from that context — no re-resolution against
//  config that may not have been saved when the run was interrupted.
//

import Foundation
import os

private let logger = Logger(subsystem: "com.octabits.relay", category: "WalletDraftCompletion")

nonisolated enum WalletDraftCompletion {
    enum Result {
        /// The split expense was created (or queued offline). `dialog` is the
        /// human-readable summary, for a confirmation notification.
        case completed(dialog: String)
        /// "Don't Split" — the draft is resolved with no expense; nothing to
        /// confirm, since the transaction was already complete without it.
        case resolved
        /// Can't finish from the notification (no friend to split with, or an
        /// unparseable manual share) — the caller should send the user into
        /// the app instead. The draft is left intact.
        case needsApp
    }

    static func complete(
        draft: TransactionDraft,
        action: SplitwiseSplitOption,
        ownShareReply: String?
    ) async -> Result {
        guard case .splitwiseWallet(_, let amount, let draftOwnShare) = draft.payload,
              let context = draft.pendingSplitContext else {
            logger.error("complete called on a draft without a Splitwise split context")
            return .needsApp
        }

        // Explicit "no" — resolve the draft, leave YNAB standing alone.
        if action == .never {
            TransactionDraftGuard.complete(draft.id)
            logger.log("draft resolved — not split")
            return .resolved
        }

        // Splitting needs a friend; if none was resolvable when the question
        // was armed, it has to be finished in-app.
        guard let friend = context.friend else {
            logger.log("split requested but no resolvable friend — needs app")
            return .needsApp
        }

        // Manual splitting needs the own-share amount — from the reply, or a
        // value already carried on the draft — parsed/validated like the form.
        let ownShare: Double?
        if action == .manual {
            let text = ownShareReply ?? draftOwnShare.map { String($0) } ?? ""
            switch SplitwiseExpenseHelper.parseOwnShare(text, amount: amount) {
            case .valid(let parsed):
                ownShare = parsed
            case .invalid(let message):
                logger.log("manual share reply invalid (\(message, privacy: .public)) — needs app")
                return .needsApp
            }
        } else {
            ownShare = nil
        }

        let formattedAmount = amount.asMoneyString
        do {
            let outcome = try await SplitwiseExpenseHelper.addExpense(
                amount: amount,
                description: context.description,
                friend: friend,
                ownShare: ownShare
            )
            let dialog = WalletAutomationDialog.splitwiseWalletDialog(
                outcome: outcome,
                formattedAmount: formattedAmount,
                description: context.description
            )
            TransactionDraftGuard.complete(draft.id)
            logger.log("completed split in background: \(dialog, privacy: .public)")
            return .completed(dialog: dialog)
        } catch {
            // A non-connectivity Splitwise failure (bad auth, validation) —
            // send the user into the app to sort it out rather than silently
            // dropping the split.
            logger.error("background split failed: \(String(describing: error), privacy: .public)")
            return .needsApp
        }
    }
}
