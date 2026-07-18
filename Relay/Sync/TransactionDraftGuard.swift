//
//  TransactionDraftGuard.swift
//  Relay
//
//  Safety net behind the wallet automations' "Ensure Completion" parameter.
//  begin() marks a transaction/expense as started and schedules a local
//  notification a short delay out; touch() pushes that deadline back out
//  again (called after every follow-up question is answered, so a normal
//  but slow-to-answer run — typing a new template name, picking a category —
//  doesn't get a premature nudge while the user is still actively working
//  through it); fail() fires the notification right away instead of
//  waiting out that window, for the case where perform() is still alive to
//  catch its own error (a real API/validation failure) and already knows
//  for certain the run won't finish; complete() cancels the notification
//  and clears the draft once the transaction actually finishes (created,
//  queued, or a deliberate "don't split").
//
//  There's no way to resume a suspended App Intent perform() call — if a
//  follow-up question gets dismissed or the process is killed outright
//  (screen locked, a Shortcuts prompt timing out), that execution is simply
//  gone, with no state left to pick back up from. This only guarantees the
//  user gets *notified* it didn't finish: the notification is registered
//  with the OS up front and only cancelled by a successful completion, so
//  it fires on its own even with zero chance to run cleanup code. Tapping it
//  opens Relay to ContinueYNABWalletTransactionView/
//  ContinueSplitwiseWalletTransactionView (see DraftNotificationRouter) to
//  actually finish the transaction from scratch, using the raw inputs saved
//  in `payload`.
//

import Foundation
import UserNotifications
import os

private let logger = Logger(subsystem: "com.octabits.relay", category: "TransactionDraftGuard")

enum TransactionDraftGuard {
    /// How long a run can go quiet (no question answered, no completion)
    /// before the reminder fires. touch() resets this on every answered
    /// question, so it's really "30s of inactivity", not "30s since the
    /// run started".
    private static let fireDelay: TimeInterval = 30

    @discardableResult
    static func begin(_ payload: TransactionDraft.Payload) -> UUID {
        let draft = TransactionDraft(id: UUID(), startedAt: Date(), payload: payload)
        var drafts = TransactionDraftStore.load()
        drafts.append(draft)
        do {
            try TransactionDraftStore.save(drafts)
        } catch {
            logger.error("failed to save transaction draft: \(String(describing: error), privacy: .public)")
        }
        scheduleNotification(for: draft)
        return draft.id
    }

    /// Pushes the reminder deadline back out to `fireDelay` from now —
    /// call after every follow-up question is answered. Re-adding a
    /// notification request with the same identifier replaces the pending
    /// one outright, and this also clears an already-*delivered* copy (the
    /// user could easily answer a later question after the first one took
    /// long enough for the original reminder to already have fired), so
    /// there's never a stale reminder sitting around once the run is
    /// visibly still making progress.
    static func touch(_ id: UUID) {
        guard let draft = TransactionDraftStore.load().first(where: { $0.id == id }) else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id.uuidString])
        scheduleNotification(for: draft)
    }

    /// Fires the reminder right away — call when perform() is about to
    /// throw. A real error (or a dismissed follow-up question that unwinds
    /// perform() while it's still alive to run this) means the run has
    /// already definitively ended without creating/queuing anything, so
    /// there's no reason to make the user wait out the usual quiet-period
    /// window before finding out.
    static func fail(_ id: UUID) {
        guard let draft = TransactionDraftStore.load().first(where: { $0.id == id }) else { return }
        scheduleNotification(for: draft, delay: 1)
    }

    static func complete(_ id: UUID) {
        var drafts = TransactionDraftStore.load()
        drafts.removeAll { $0.id == id }
        do {
            try TransactionDraftStore.save(drafts)
        } catch {
            logger.error("failed to save transaction drafts: \(String(describing: error), privacy: .public)")
        }
        // Covers both cases: the notification hasn't fired yet (e.g. a fast
        // run), or it already has (e.g. the user was mid-checkout and only
        // just got back to answering a follow-up question) — either way,
        // once the transaction's actually done it shouldn't linger.
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id.uuidString])
        center.removeDeliveredNotifications(withIdentifiers: [id.uuidString])
    }

    private static func scheduleNotification(for draft: TransactionDraft, delay: TimeInterval = fireDelay) {
        guard NotificationsPreferenceStore.isEnabled else { return }

        let content = UNMutableNotificationContent()
        content.title = "Transaction Incomplete"
        content.body = "\(draft.summary). Tap to continue."
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        let request = UNNotificationRequest(identifier: draft.id.uuidString, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                logger.error("failed to schedule draft notification: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
