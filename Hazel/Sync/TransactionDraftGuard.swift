//
//  TransactionDraftGuard.swift
//  Hazel
//
//  Safety net behind the wallet automations' "Ensure Completion" parameter.
//  begin() marks a transaction/expense as started and schedules a local
//  notification a short delay out; touch() pushes that deadline back out
//  again (called after every follow-up question is answered, so a normal
//  but slow-to-answer run — typing a new template name, picking a category —
//  doesn't get a premature nudge while the user is still actively working
//  through it); complete() cancels the notification and clears the draft
//  once the transaction actually finishes (created, queued, or a deliberate
//  "don't split").
//
//  There's no way to resume a suspended App Intent perform() call — if a
//  follow-up question gets dismissed or the process is killed outright
//  (screen locked, a Shortcuts prompt timing out), that execution is simply
//  gone, with no state left to pick back up from. This only guarantees the
//  user gets *notified* it didn't finish: the notification is registered
//  with the OS up front and only cancelled by a successful completion, so
//  it fires on its own even with zero chance to run cleanup code. Tapping it
//  opens Hazel to ContinueYNABWalletTransactionView/
//  ContinueSplitwiseWalletTransactionView (see DraftNotificationRouter) to
//  actually finish the transaction from scratch, using the raw inputs saved
//  in `payload`.
//

import Foundation
import UserNotifications
import os

private let logger = Logger(subsystem: "com.pentlandFirth.Hazel", category: "TransactionDraftGuard")

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

    private static func scheduleNotification(for draft: TransactionDraft) {
        let content = UNMutableNotificationContent()
        content.title = "Continue Adding Transaction"
        content.body = "\(draft.summary) — still needs to be added to \(draft.service.displayName). Tap to finish."
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: fireDelay, repeats: false)
        let request = UNNotificationRequest(identifier: draft.id.uuidString, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                logger.error("failed to schedule draft notification: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
