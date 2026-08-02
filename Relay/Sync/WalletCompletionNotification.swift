//
//  WalletCompletionNotification.swift
//  Relay
//
//  Shared "success" confirmation banner for wallet automations and
//  notification quick-reply completions.
//

import Foundation
import UserNotifications
import os

private nonisolated let walletCompletionLogger = Logger(subsystem: Const.loggerSubsystem, category: "WalletCompletionNotification")

nonisolated enum WalletCompletionNotification {
    static let categoryIdentifier = "WALLET_COMPLETION_CONFIRMATION"

    /// `historyEntryID`, when set, is the id of the just-recorded
    /// TransactionHistoryEntry this confirmation is for — carried in
    /// userInfo so tapping the notification opens that transaction's detail
    /// view (see DraftNotificationRouter) instead of just the overview.
    static func postConfirmation(
        title: String = String(localized: "Split Added"),
        dialog: String,
        historyEntryID: UUID? = nil
    ) {
        guard NotificationsPreferenceStore.isEnabled else { return }
        walletCompletionLogger.log("posting split confirmation")

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = dialog
        content.categoryIdentifier = categoryIdentifier
        if let historyEntryID {
            content.userInfo = ["historyEntryID": historyEntryID.uuidString]
        }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                walletCompletionLogger.error("failed to post completion confirmation: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Clears any success confirmations still sitting in Notification Center
    /// once the user has opened the app — they've served their purpose.
    static func clearDelivered() async {
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications()
        let ids = delivered
            .filter { $0.request.content.categoryIdentifier == categoryIdentifier }
            .map(\.request.identifier)
        guard !ids.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }
}