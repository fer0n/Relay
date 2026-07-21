//
//  WalletSplitNotification.swift
//  Relay
//
//  The interactive-notification category behind answering a wallet
//  transaction's "split with Splitwise?" question straight from the draft
//  reminder, without opening the app. The three actions mirror the intent's
//  live SplitwiseSplitOption prompt (Split Equally / Manually / Don't
//  Split); the manual case is a text-input action whose reply is the user's
//  own share. Registered once in DraftNotificationRouter.start(); attached
//  to a draft notification only by TransactionDraftGuard.armSplitChoice,
//  i.e. only when the run actually reached that question with everything
//  else resolved (see TransactionDraft.PendingSplitContext). Handled in
//  DraftNotificationRouter.didReceive, which hands off to
//  WalletDraftCompletion.
//

import UserNotifications

enum WalletSplitNotification {
    static let categoryIdentifier = "WALLET_SPLIT_CHOICE"
    static let equallyAction = "WALLET_SPLIT_EQUALLY"
    static let manualAction = "WALLET_SPLIT_MANUAL"
    static let noneAction = "WALLET_SPLIT_NONE"

    static var category: UNNotificationCategory {
        let equally = UNNotificationAction(
            identifier: equallyAction,
            title: String(localized: "Split Equally"),
            options: []
        )
        // A text-input action so the one extra value manual splitting needs —
        // the user's own share — can be typed inline; parsed/validated by
        // SplitwiseExpenseHelper.parseOwnShare, same as the in-app form.
        let manual = UNTextInputNotificationAction(
            identifier: manualAction,
            title: String(localized: "Split Manually…"),
            options: [],
            textInputButtonTitle: String(localized: "Split"),
            textInputPlaceholder: String(localized: "Your share, e.g. 12.50")
        )
        let none = UNNotificationAction(
            identifier: noneAction,
            title: String(localized: "Don't Split"),
            options: []
        )
        // No .foreground on any action: they complete in the background;
        // WalletDraftCompletion only re-opens the app when it genuinely
        // can't finish (no friend resolvable, invalid manual share).
        return UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [equally, manual, none],
            intentIdentifiers: [],
            options: []
        )
    }
}
