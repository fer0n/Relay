//
//  WalletDraftCompletion.swift
//  Relay
//
//  Answers the "split?" question from a notification action in the
//  background, doing only the split half via the same SplitExpenseService /
//  WalletAutomationDialog path the intents use. On the YNAB automation the
//  transaction is already committed, so this is an optional side-split; on
//  the ledger-only one the expense *is* the split.
//
//  Only for a `.ledgerWallet` draft carrying a PendingSplitContext, i.e. one
//  armed at the split question with everything already resolved — no
//  re-resolution against config an interrupted run may not have saved.
//

import Foundation
import os

private nonisolated let logger = Logger(subsystem: Const.loggerSubsystem, category: "WalletDraftCompletion")

nonisolated enum WalletDraftCompletion {
    enum Result {
        /// The split expense was created (or queued offline). `title`/`dialog`
        /// are ready to show as-is in a confirmation notification.
        case completed(title: String, dialog: String)
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
        action: SplitOption,
        ownShareReply: String?
    ) async -> Result {
        guard case .ledgerWallet(_, let amount, let draftOwnShare) = draft.payload,
              let context = draft.pendingSplitContext else {
            logger.error("complete called on a draft without a split context")
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
            switch SplitExpenseService.parseOwnShare(text, amount: amount) {
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
            let outcome = try await SplitExpenseService.addExpense(
                amount: amount,
                description: context.description,
                friend: friend,
                ownShare: ownShare,
                date: draft.startedAt,
                merchant: draft.merchant
            )
            let dialog = WalletAutomationDialog.ledgerWalletDialog(
                outcome: outcome,
                formattedAmount: formattedAmount,
                description: context.description
            )
            let isQueued: Bool = if case .queued = outcome { true } else { false }
            WalletDraftConfirmation.commitClaim(for: draft, wroteEntry: !isQueued)
            TransactionDraftGuard.complete(draft.id)
            logger.log("completed split in background: \(dialog, privacy: .public)")
            let content = WalletAutomationDialog.notificationContent(
                isQueued: isQueued,
                formattedAmount: formattedAmount,
                name: context.description,
                defaultTitle: String(localized: "Split Added"),
                dialog: dialog
            )
            return .completed(title: content.title, dialog: content.body)
        } catch {
            // A non-connectivity failure (bad auth, validation) —
            // send the user into the app to sort it out rather than silently
            // dropping the split.
            logger.error("background split failed: \(String(describing: error), privacy: .public)")
            return .needsApp
        }
    }
}
