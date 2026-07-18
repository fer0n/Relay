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
    /// time the response arrives.
    func start() {
        UNUserNotificationCenter.current().delegate = self
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let identifier = response.notification.request.identifier
        Task { @MainActor in
            if identifier == PendingOperationQueue.reminderNotificationID {
                DraftNotificationRouter.shared.pendingQueueReminderTapped = true
            } else if let id = UUID(uuidString: identifier) {
                DraftNotificationRouter.shared.pendingDraftID = id
            } else {
                logger.error("notification identifier wasn't recognized: \(identifier, privacy: .public)")
            }
            completionHandler()
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
