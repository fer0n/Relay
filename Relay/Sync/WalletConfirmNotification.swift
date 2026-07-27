//
//  WalletConfirmNotification.swift
//  Relay
//
//  The interactive-notification category behind the "Confirm Transaction"
//  reminder an automation with "Require Confirmation" leaves behind (see
//  TransactionDraftGuard.beginAwaitingConfirmation). That reminder exists
//  precisely because Relay refused to add the transaction on its own, so the
//  two answers it needs — yes, add it; no, drop it — belong on the banner
//  rather than behind opening the app: needing a round trip through Relay to
//  approve every purchase would make the parameter too annoying to leave on.
//
//  Registered once in DraftNotificationRouter.start() and handled in its
//  didReceive, which hands "Add" off to WalletDraftConfirmation. Discard is
//  answered there directly — it's just dropping the draft.
//

import UserNotifications

nonisolated enum WalletConfirmNotification {
    static let categoryIdentifier = "WALLET_CONFIRM_TRANSACTION"
    static let addAction = "WALLET_CONFIRM_ADD"
    static let discardAction = "WALLET_CONFIRM_DISCARD"

    static var category: UNNotificationCategory {
        // No .foreground on "Add": it completes in the background wherever
        // the merchant and card are already mapped, and only pulls the user
        // into Relay (via notifyNeedsApp) when something genuinely still has
        // to be chosen.
        let add = UNNotificationAction(
            identifier: addAction,
            title: String(localized: "Add"),
            options: []
        )
        // .destructive for the red styling — it throws the sighting away.
        // Not .authenticationRequired: the draft is recoverable in the sense
        // that matters (the purchase can always be added by hand later), and
        // requiring a Face ID unlock to dismiss a banner would defeat the
        // point of answering from the lock screen.
        let discard = UNNotificationAction(
            identifier: discardAction,
            title: String(localized: "Discard"),
            options: [.destructive]
        )
        return UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [add, discard],
            intentIdentifiers: [],
            options: []
        )
    }
}
