//
//  DraftNotificationRouter.swift
//  Relay
//
//  Bridges an external trigger into SwiftUI navigation — either a tapped
//  notification, or an App Intent that just brought Relay to the foreground
//  and wants to land on a specific screen. Three kinds arrive here: a
//  "Continue Adding Transaction" notification (see TransactionDraftGuard),
//  whose identifier is the draft's UUID; the fixed-identifier pending-queue
//  reminder (see PendingOperationQueue); and ImportSplitwiseFileIntent
//  setting pendingSplitwiseImport directly once it's staged an import.
//  Either way the trigger just flags which destination fired; ContentView
//  reacts by pushing it.
//

import Foundation
import Observation
import UserNotifications
import os

private let logger = Logger(subsystem: "com.octabits.relay", category: "DraftNotificationRouter")

@MainActor
@Observable
final class DraftNotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = DraftNotificationRouter()

    /// Set when the user taps a draft notification; ContentView observes
    /// this and clears it once it's acted on.
    var pendingDraftID: UUID?

    /// Set when the user taps the pending-queue reminder; ContentView
    /// observes this and clears it once it's acted on.
    var pendingQueueReminderTapped = false

    /// Set when the user taps a wallet "Transaction Added" / "Split Added"
    /// success notification carrying a history entry id; ContentView observes
    /// this and opens that transaction's detail view, then clears it.
    var pendingHistoryEntryID: UUID?

    /// Set by ImportSplitwiseFileIntent right after it stages a parsed
    /// import (not notification-driven, but the same one-shot signal shape)
    /// — ContentView observes this and clears it once it's acted on.
    var pendingSplitwiseImport = false

    /// Set by ContentView's `.onOpenURL` when a bank statement file arrives
    /// via the Share Sheet's "Copy to Relay" action — same one-shot signal
    /// shape as `pendingDraftID`, but carries the file itself since there's
    /// no separate staging store for it until a destination is picked.
    var pendingSharedFile: SharedStatementFile?

    private override init() {
        super.init()
    }

    /// Must be called as early as possible (RelayApp.init()) — UNUserNotificationCenter
    /// only delivers a tap response to a delegate that's already set by the
    /// time the response arrives, and its categories must be registered
    /// before a notification carrying one is delivered.
    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([WalletSplitNotification.category])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let identifier = response.notification.request.identifier
        let actionIdentifier = response.actionIdentifier
        let replyText = (response as? UNTextInputNotificationResponse)?.userText
        // A wallet success notification carries the id of the transaction it
        // confirmed, so its tap opens that entry's detail view rather than
        // resolving to nothing (its identifier is a throwaway UUID).
        let historyEntryID = response.notification.request.content.userInfo["historyEntryID"] as? String
        Task { @MainActor in
            if identifier == PendingOperationQueue.reminderNotificationID {
                DraftNotificationRouter.shared.pendingQueueReminderTapped = true
            } else if let historyEntryID, let id = UUID(uuidString: historyEntryID) {
                DraftNotificationRouter.shared.pendingHistoryEntryID = id
            } else if let id = UUID(uuidString: identifier) {
                await DraftNotificationRouter.shared.handleDraftResponse(
                    id: id,
                    actionIdentifier: actionIdentifier,
                    replyText: replyText
                )
            } else {
                logger.error("notification identifier wasn't recognized: \(identifier, privacy: .public)")
            }
            completionHandler()
        }
    }

    /// Routes a draft-notification response: a plain tap opens the draft as
    /// before, while a split-choice action tries to finish the transaction in
    /// the background (WalletDraftCompletion), only falling back to opening
    /// the app when it can't.
    private func handleDraftResponse(id: UUID, actionIdentifier: String, replyText: String?) async {
        logger.log("draft response id=\(id.uuidString, privacy: .public) action=\(actionIdentifier, privacy: .public)")
        
        guard let draft = TransactionDraftStore.load().first(where: { $0.id == id }) else {
            // Already completed/dismissed since the notification fired — if
            // it's a default tap for a successfully-completed transaction,
            // just stay on the main screen instead of trying to open a
            // non-existent draft.
            return
        }
        
        let splitAction: SplitwiseSplitOption
        switch actionIdentifier {
        case WalletSplitNotification.equallyAction:
            splitAction = .always
        case WalletSplitNotification.manualAction:
            splitAction = .manual
        case WalletSplitNotification.noneAction:
            splitAction = .never
        default:
            // Default tap (or dismiss handed to us) — open the draft in-app.
            // We know the draft exists because of the guard above.
            pendingDraftID = id
            return
        }

        switch await WalletDraftCompletion.complete(draft: draft, action: splitAction, ownShareReply: replyText) {
        case .completed(let dialog):
            WalletCompletionNotification.postConfirmation(dialog: dialog, historyEntryID: TransactionHistoryStore.newestEntryID())
        case .resolved:
            // "Don't Split" — the transaction was already complete, so there's
            // nothing to confirm.
            break
        case .needsApp:
            // Couldn't finish from the notification — re-nudge the user into
            // the app to complete it by hand. (A background action doesn't
            // bring Relay forward, so setting pendingDraftID alone wouldn't
            // reach them.)
            TransactionDraftGuard.notifyNeedsApp(id)
        }
    }

    /// Shows the notification even while Relay is already in the
    /// foreground — otherwise a fired reminder would be silently dropped if
    /// the user happened to have the app open.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}
