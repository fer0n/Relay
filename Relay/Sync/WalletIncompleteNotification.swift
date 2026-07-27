//
//  WalletIncompleteNotification.swift
//  Relay
//
//  The interactive-notification category behind the plain "Transaction
//  Incomplete" reminder (see TransactionDraftGuard.scheduleNotification) —
//  the fallback that fires whenever an automation run got interrupted
//  without finishing. Its only action is Discard, for throwing the draft
//  away straight from the banner instead of opening Relay just to drop it.
//
//  Safe to offer unconditionally: whatever this reminder is protecting is,
//  by definition, still unwritten — a run that had already committed
//  something transitions or completes the draft rather than leaving it on
//  this plain reminder (see TransactionDraftGuard.transition, used when the
//  YNAB half lands and only the Splitwise split is still open). So
//  discarding here only ever drops the part that never happened, exactly
//  like WalletConfirmNotification's Discard.
//
//  Registered once in DraftNotificationRouter.start() and handled in its
//  didReceive, which just completes the draft (TransactionDraftGuard.complete).
//

import UserNotifications

nonisolated enum WalletIncompleteNotification {
    static let categoryIdentifier = "WALLET_TRANSACTION_INCOMPLETE"
    static let discardAction = "WALLET_INCOMPLETE_DISCARD"

    static var category: UNNotificationCategory {
        // .destructive for the red styling — same treatment as
        // WalletConfirmNotification's Discard, and for the same reason:
        // nothing already written is at stake, just the parked draft.
        let discard = UNNotificationAction(
            identifier: discardAction,
            title: String(localized: "Discard"),
            options: [.destructive]
        )
        return UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [discard],
            intentIdentifiers: [],
            options: []
        )
    }
}
