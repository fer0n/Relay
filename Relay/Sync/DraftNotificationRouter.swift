//
//  DraftNotificationRouter.swift
//  Relay
//
//  Bridges an external trigger into SwiftUI navigation — a tapped
//  notification, or an App Intent that brought Relay to the foreground and
//  wants a specific screen. The trigger only flags which destination fired;
//  ContentView reacts by pushing it.
//

import Foundation
import Observation
import UserNotifications
import os

private nonisolated let logger = Logger(subsystem: Const.loggerSubsystem, category: "DraftNotificationRouter")

@MainActor
@Observable
final class DraftNotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = DraftNotificationRouter()

    // Each of these is a one-shot signal: something sets it, ContentView acts on
    // it and clears it.
    var pendingDraftID: UUID?
    var pendingQueueReminderTapped = false
    /// From a wallet success notification — opens that transaction's detail view.
    var pendingHistoryEntryID: UUID?
    /// Set by ImportSplitwiseFileIntent right after it stages a parsed import.
    var pendingSplitwiseImport = false
    /// Set by `.onOpenURL` for a shared statement file. Carries the file itself,
    /// since nothing stages it until a destination is picked.
    var pendingSharedFile: SharedStatementFile?
    /// Set by QuickActionSceneDelegate for the Home Screen quick action.
    var pendingQuickActionNewTransaction = false

    private override init() {
        super.init()
    }

    /// Must be called as early as possible (RelayApp.init()): a tap response only
    /// reaches a delegate already set when it arrives, and categories must be
    /// registered before a notification carrying one is delivered.
    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            WalletSplitNotification.category,
            WalletConfirmNotification.category,
            WalletIncompleteNotification.category
        ])
    }

    /// The `async` half of the delegate requirement, not the completion-handler
    /// one: both `UNNotificationResponse` and the handler are non-Sendable, so
    /// that shape had to smuggle them into a `Task { @MainActor }` — a data race.
    ///
    /// Deliberately main-actor isolated, *not* `nonisolated`: the system runs the
    /// hidden completion handler on whatever executor this returns on, and that
    /// handler tears down the notification's UI ("Call must be made on main
    /// thread"). A `nonisolated` version resumes on the generic executor after
    /// any `await`, so every tap crashed.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let identifier = response.notification.request.identifier
        let actionIdentifier = response.actionIdentifier
        let replyText = (response as? UNTextInputNotificationResponse)?.userText
        // A wallet success notification's own identifier is a throwaway UUID, so
        // routing goes by the transaction id it carries instead.
        let historyEntryID = response.notification.request.content.userInfo["historyEntryID"] as? String
        await route(
            identifier: identifier,
            actionIdentifier: actionIdentifier,
            replyText: replyText,
            historyEntryID: historyEntryID
        )
    }

    private func route(
        identifier: String,
        actionIdentifier: String,
        replyText: String?,
        historyEntryID: String?
    ) async {
        if identifier == PendingOperationQueue.reminderNotificationID {
            pendingQueueReminderTapped = true
        } else if let historyEntryID, let id = UUID(uuidString: historyEntryID) {
            pendingHistoryEntryID = id
        } else if let id = UUID(uuidString: identifier) {
            await handleDraftResponse(
                id: id,
                actionIdentifier: actionIdentifier,
                replyText: replyText
            )
        } else {
            logger.error("notification identifier wasn't recognized: \(identifier, privacy: .public)")
        }
    }

    /// A plain tap opens the draft; a split-choice or confirm action tries to
    /// finish it in the background, falling back to opening the app.
    private func handleDraftResponse(id: UUID, actionIdentifier: String, replyText: String?) async {
        logger.log("draft response id=\(id.uuidString, privacy: .public) action=\(actionIdentifier, privacy: .public)")

        guard let draft = TransactionDraftStore.load().first(where: { $0.id == id }) else {
            // Already completed or dismissed since the notification fired, so
            // stay on the main screen rather than opening a nonexistent draft.
            return
        }

        // Answers to a "Confirm Transaction" reminder — a purchase Relay saw but
        // deliberately didn't add.
        switch actionIdentifier {
        case WalletConfirmNotification.discardAction, WalletIncompleteNotification.discardAction:
            // The claim behind it is left alone: it doesn't shadow an automation
            // that can write, so saying no here doesn't block the purchase from
            // being added properly later.
            TransactionDraftGuard.complete(id)
            logger.log("discarded draft id=\(id.uuidString, privacy: .public)")
            return
        case WalletConfirmNotification.addAction:
            switch await WalletDraftConfirmation.confirm(draft) {
            case .completed(let title, let dialog):
                WalletCompletionNotification.postConfirmation(title: title, dialog: dialog, historyEntryID: TransactionHistoryStore.newestEntryID())
            case .followUpPosted:
                // The split question took over this draft's reminder slot, so a
                // "done" banner on top would contradict it.
                break
            case .needsApp:
                // A background action doesn't bring Relay forward, so
                // pendingDraftID alone wouldn't reach the user.
                TransactionDraftGuard.notifyNeedsApp(id)
            }
            return
        default:
            break
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
            pendingDraftID = id
            return
        }

        switch await WalletDraftCompletion.complete(draft: draft, action: splitAction, ownShareReply: replyText) {
        case .completed(let title, let dialog):
            WalletCompletionNotification.postConfirmation(title: title, dialog: dialog, historyEntryID: TransactionHistoryStore.newestEntryID())
        case .resolved:
            // "Don't Split" — the transaction was already complete.
            break
        case .needsApp:
            // Couldn't finish from the notification, and a background action
            // doesn't bring Relay forward, so re-nudge instead.
            TransactionDraftGuard.notifyNeedsApp(id)
        }
    }

    /// Shows the notification even in the foreground — otherwise a fired reminder
    /// is silently dropped whenever the app happens to be open. Main-actor
    /// isolated for the same reason as `didReceive` above.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}
