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
//  opens Relay to ContinueWalletTransactionView (see
//  DraftNotificationRouter) to
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
    ///
    /// Whether the rescheduled reminder carries the split actions follows
    /// the draft's `pendingSplitContext`: it's set only while the split
    /// choice is the open question (armSplitChoice … disarmSplitChoice), so
    /// a touch before or after that window reschedules plain, and one during
    /// it keeps the actions.
    static func touch(_ id: UUID) {
        guard let draft = TransactionDraftStore.load().first(where: { $0.id == id }) else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id.uuidString])
        scheduleNotification(for: draft)
    }

    /// Runs `ask` (the intent's own `$…​.requestValue` for the live "split
    /// with Splitwise?" choice) with the Split Equally / Manually / Don't
    /// Split quick-reply actions armed on `draftId` for its duration, then
    /// clears them. Both wallet automations call this at their `.ask` branch;
    /// keeping arm and disarm paired here means a caller can't leave a draft
    /// armed past the question, and preserves the one subtlety that matters:
    /// if `ask` throws (the prompt was dismissed — exactly what the quick
    /// reply is for), the context is deliberately *left armed* so the intent's
    /// catch → fail() fires the reminder still carrying the actions. On a
    /// normal answer it disarms, so any *later* interruption reschedules a
    /// plain reminder. `draftId` nil (Ensure Completion off) just runs `ask`.
    static func askSplitChoice(
        draftId: UUID?,
        context: TransactionDraft.PendingSplitContext,
        ask: () async throws -> SplitwiseSplitOption
    ) async rethrows -> SplitwiseSplitOption {
        guard let draftId else { return try await ask() }
        armSplitChoice(draftId, context: context)
        let choice = try await ask() // a throw here leaves it armed, on purpose
        disarmSplitChoice(draftId)
        return choice
    }

    /// Saves the expense description + resolved friend onto the draft and
    /// reschedules its reminder carrying the split quick-reply actions. Also
    /// resets the quiet-period timer, since the user is now being actively
    /// prompted. Private — always paired with disarm via askSplitChoice.
    private static func armSplitChoice(_ id: UUID, context: TransactionDraft.PendingSplitContext) {
        var drafts = TransactionDraftStore.load()
        guard let index = drafts.firstIndex(where: { $0.id == id }) else { return }
        drafts[index].pendingSplitContext = context
        do {
            try TransactionDraftStore.save(drafts)
        } catch {
            logger.error("failed to save split context on draft: \(String(describing: error), privacy: .public)")
        }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id.uuidString])
        scheduleNotification(for: drafts[index])
    }

    /// Clears the armed split context once the split choice has been answered.
    /// From here on any interruption (or a fail()) reschedules a *plain*
    /// reminder, since the quick-reply actions only make sense while the split
    /// is still the open question. Rescheduling itself is left to the touch()
    /// that immediately follows. Private — see askSplitChoice.
    private static func disarmSplitChoice(_ id: UUID) {
        var drafts = TransactionDraftStore.load()
        guard let index = drafts.firstIndex(where: { $0.id == id }),
              drafts[index].pendingSplitContext != nil else { return }
        drafts[index].pendingSplitContext = nil
        do {
            try TransactionDraftStore.save(drafts)
        } catch {
            logger.error("failed to clear split context on draft: \(String(describing: error), privacy: .public)")
        }
    }

    /// Re-delivers a *plain* draft reminder right away after a notification
    /// action couldn't finish the transaction on its own (no friend to split
    /// with, an unparseable manual share). The draft still exists, so tapping
    /// this opens TransactionDetailView to finish it by hand — and it deliberately
    /// drops the split actions so the user isn't offered a quick reply that
    /// already failed once.
    static func notifyNeedsApp(_ id: UUID) {
        guard let draft = TransactionDraftStore.load().first(where: { $0.id == id }) else { return }
        scheduleNotification(
            for: draft,
            delay: 1,
            body: String(localized: "\(draft.summary). Couldn't finish automatically — tap to complete in Relay."),
            splitActions: false
        )
    }

    /// Fires the reminder right away — call when perform() is about to
    /// throw. A real error (or a dismissed follow-up question that unwinds
    /// perform() while it's still alive to run this) means the run has
    /// already definitively ended without creating/queuing anything, so
    /// there's no reason to make the user wait out the usual quiet-period
    /// window before finding out. Keeps the split actions when the throw
    /// happened *at* the split question (context still armed) — dismissing
    /// that prompt is exactly the case the quick reply is for.
    ///
    /// But if the reminder has *already* fired, don't schedule it again:
    /// re-adding the request re-alerts the same notification. This happens
    /// when a background run's requestValue suspends past the quiet-period
    /// window (the reminder fires at 30s), and then — when the app is next
    /// opened — the suspended intent resumes, is abandoned, and unwinds
    /// through here. Re-firing then is the duplicate the user sees on open;
    /// it already fired, so leave it.
    static func fail(_ id: UUID) async {
        guard let draft = TransactionDraftStore.load().first(where: { $0.id == id }) else { return }
        let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
        guard !delivered.contains(where: { $0.request.identifier == id.uuidString }) else {
            logger.log("fail: reminder already delivered for id=\(id.uuidString, privacy: .public) — not re-firing")
            return
        }
        scheduleNotification(for: draft, delay: 1)
    }

    /// Repoints an existing draft at a new payload while keeping its id — and
    /// therefore its notification identifier. Used when a wallet run commits
    /// its YNAB half and the guard should switch to protecting only the
    /// remaining Splitwise split: reusing the id (instead of complete() +
    /// begin(), which mint a second identifier) keeps the whole run to a
    /// single reminder slot, so it can never surface two notifications at
    /// once — same-identifier scheduling replaces rather than adds. Clears any
    /// already-delivered copy of the old reminder and reschedules a fresh
    /// (plain) one for the new payload; the split actions are armed separately.
    static func transition(_ id: UUID, to payload: TransactionDraft.Payload) {
        var drafts = TransactionDraftStore.load()
        guard let index = drafts.firstIndex(where: { $0.id == id }) else { return }
        drafts[index] = TransactionDraft(id: id, startedAt: drafts[index].startedAt, payload: payload)
        do {
            try TransactionDraftStore.save(drafts)
        } catch {
            logger.error("failed to save transitioned draft: \(String(describing: error), privacy: .public)")
        }
        logger.log("transitioned draft id=\(id.uuidString, privacy: .public)")
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id.uuidString])
        scheduleNotification(for: drafts[index])
    }

    static func complete(_ id: UUID) {
        logger.log("completing draft id=\(id.uuidString, privacy: .public)")
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

    /// `splitActions` overrides whether the reminder carries the split
    /// quick-reply actions; when nil (the default) it follows the draft's
    /// armed `pendingSplitContext`, so every scheduling path — begin, touch,
    /// and especially fail (the "caught" path) — keeps the actions while the
    /// split is the open question and drops them otherwise. notifyNeedsApp
    /// passes `false` to force a plain reminder even though the context is
    /// still set.
    private static func scheduleNotification(
        for draft: TransactionDraft,
        delay: TimeInterval = fireDelay,
        body: String? = nil,
        splitActions: Bool? = nil
    ) {
        guard NotificationsPreferenceStore.isEnabled else { return }

        let attachActions = splitActions ?? (draft.pendingSplitContext != nil)
        logger.log("scheduling draft reminder id=\(draft.id.uuidString, privacy: .public) delay=\(delay, privacy: .public) actions=\(attachActions, privacy: .public)")

        let content = UNMutableNotificationContent()
        content.sound = .default
        if attachActions {
            // The split-choice reminder: the transaction (YNAB) is already
            // done, so this isn't "incomplete" — it just offers the optional
            // split. Title carries the summary, body poses the question the
            // Split Equally / Manually / Don't Split actions answer.
            content.categoryIdentifier = WalletSplitNotification.categoryIdentifier
            content.title = draft.summary
            if let friendName = draft.pendingSplitContext?.friend?.firstName {
                content.body = String(localized: "Split with \(friendName)?")
            } else {
                content.body = String(localized: "Split this expense?")
            }
        } else {
            content.title = String(localized: "Transaction Incomplete")
            content.body = body ?? String(localized: "\(draft.summary). Tap to continue.")
        }

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        let request = UNNotificationRequest(identifier: draft.id.uuidString, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                logger.error("failed to schedule draft notification: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
