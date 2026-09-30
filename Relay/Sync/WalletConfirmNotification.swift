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
//  `splitCategory` is the same reminder for a YNAB purchase whose split would
//  otherwise be a second question: it asks both at once.
//

import UserNotifications

nonisolated enum WalletConfirmNotification {
    static let categoryIdentifier = "WALLET_CONFIRM_TRANSACTION"
    static let addAction = "WALLET_CONFIRM_ADD"
    static let discardAction = "WALLET_CONFIRM_DISCARD"

    static let splitCategoryIdentifier = "WALLET_CONFIRM_SPLIT"
    static let addSplitEquallyAction = "WALLET_CONFIRM_ADD_SPLIT_EQUALLY"
    static let addSplitManualAction = "WALLET_CONFIRM_ADD_SPLIT_MANUAL"
    static let addWithoutSplitAction = "WALLET_CONFIRM_ADD_NO_SPLIT"

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
        return UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [add, discard],
            intentIdentifiers: [],
            options: []
        )
    }

    static var splitCategory: UNNotificationCategory {
        let equally = UNNotificationAction(
            identifier: addSplitEquallyAction,
            title: String(localized: "Add & Split Equally"),
            options: []
        )
        let manual = UNTextInputNotificationAction(
            identifier: addSplitManualAction,
            title: String(localized: "Add & Split Manually…"),
            options: [],
            textInputButtonTitle: String(localized: "Add"),
            textInputPlaceholder: String(localized: "Your share, e.g. 12.50")
        )
        let withoutSplit = UNNotificationAction(
            identifier: addWithoutSplitAction,
            title: String(localized: "Add Without Splitting"),
            options: []
        )
        return UNNotificationCategory(
            identifier: splitCategoryIdentifier,
            actions: [equally, manual, withoutSplit, discard],
            intentIdentifiers: [],
            options: []
        )
    }

    private static var discard: UNNotificationAction {
        // .destructive for the red styling — it throws the sighting away.
        // Not .authenticationRequired: the draft is recoverable in the sense
        // that matters (the purchase can always be added by hand later), and
        // requiring a Face ID unlock to dismiss a banner would defeat the
        // point of answering from the lock screen.
        UNNotificationAction(
            identifier: discardAction,
            title: String(localized: "Discard"),
            options: [.destructive]
        )
    }
}
