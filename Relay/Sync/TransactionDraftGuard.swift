//
//  TransactionDraftGuard.swift
//  Relay
//
//  Safety net behind the wallet automations' "Ensure Completion" parameter.
//
//  A suspended App Intent perform() can't be resumed — a dismissed follow-up
//  question or a killed process (screen lock, prompt timeout) loses that
//  execution outright. So the notification is registered with the OS up front
//  and only cancelled by a successful complete(): it fires on its own even
//  with zero chance to run cleanup code. Tapping it opens
//  ContinueWalletTransactionView (see DraftNotificationRouter), which redoes
//  the transaction from the raw inputs in `payload`.
//

import Foundation
import UserNotifications
import os

private nonisolated let logger = Logger(subsystem: Const.loggerSubsystem, category: "TransactionDraftGuard")

nonisolated enum TransactionDraftGuard {
    /// How long a run can go quiet before the reminder fires. touch() resets
    /// it, so this is inactivity, not time since the run started.
    private static let fireDelay: TimeInterval = 30

    /// See withHeartbeat. The gap absorbs a late renewal.
    private static let heartbeatDeadline: TimeInterval = 8
    private static let heartbeatInterval: TimeInterval = 3

    @discardableResult
    static func begin(_ payload: TransactionDraft.Payload) -> UUID {
        let draft = create(payload)
        scheduleNotification(for: draft)
        return draft.id
    }

    /// For "Require Confirmation" automations, which Relay never adds on its
    /// own. The quiet-period delay doubles as a grace window for the other
    /// automation to supersede it (see TransactionClaim.supersededConfirmations).
    @discardableResult
    static func beginAwaitingConfirmation(_ payload: TransactionDraft.Payload, source: String) -> UUID {
        let draft = create(payload)
        scheduleNotification(
            for: draft,
            title: String(localized: "Confirm Transaction"),
            body: String(localized: "\(draft.summary), seen by \"\(source)\". Add it?"),
            categoryIdentifier: WalletConfirmNotification.categoryIdentifier,
            splitActions: false
        )
        return draft.id
    }

    /// A draft whose reminder is the split question itself — on the Splitwise
    /// path that doubles as the confirmation, "Don't Split" creating nothing.
    @discardableResult
    static func beginAwaitingSplitChoice(
        _ payload: TransactionDraft.Payload,
        context: TransactionDraft.PendingSplitContext
    ) -> UUID {
        let draft = create(payload, context: context)
        scheduleNotification(for: draft)
        return draft.id
    }

    /// Starts — or takes over `existing`, keeping the run to one reminder slot —
    /// for a merchant whose template belongs in Relay's form rather than a chain
    /// of Shortcuts prompts. Stays on the quiet period, since the intent asks to
    /// continue in the foreground straight after.
    @discardableResult
    static func beginNeedsTemplate(_ payload: TransactionDraft.Payload, existing: UUID?) -> UUID {
        let draft = existing.flatMap { loadDraft($0) } ?? create(payload)
        clearDelivered(draft.id)
        scheduleNotification(for: draft)
        return draft.id
    }

    private static func create(
        _ payload: TransactionDraft.Payload,
        context: TransactionDraft.PendingSplitContext? = nil
    ) -> TransactionDraft {
        var draft = TransactionDraft(id: UUID(), startedAt: Date(), payload: payload)
        draft.pendingSplitContext = context
        save(trimmedToLimit: TransactionDraftStore.load() + [draft])
        return draft
    }

    /// Ordered by `startedAt`, not insertion order, since `transition(_:to:)`
    /// keeps a draft's original id/startedAt rather than re-adding it.
    static func splitByLimit(_ drafts: [TransactionDraft], limit: Int) -> (kept: [TransactionDraft], dropped: [TransactionDraft]) {
        guard drafts.count > limit else { return (drafts, []) }
        let sorted = drafts.sorted { $0.startedAt > $1.startedAt }
        return (Array(sorted.prefix(limit)), Array(sorted[limit...]))
    }

    /// Called when Settings disappears, not per picker change, so a lower value
    /// can be dialed back up before it discards anything.
    static func enforceLimit() {
        save(trimmedToLimit: TransactionDraftStore.load())
    }

    /// Puts the reminder back on the quiet period, clearing a delivered copy so
    /// none outlives a run that's still progressing.
    static func touch(_ id: UUID) {
        guard let draft = loadDraft(id) else { return }
        clearDelivered(id)
        scheduleNotification(for: draft)
    }

    /// Runs a follow-up question with its reminder on the heartbeat deadline
    /// instead of the quiet period — a dead-man's switch for the process being
    /// killed with the question on screen (screen lock, prompt timeout), which
    /// runs no cleanup code, leaving the fire time the only way to notice.
    /// Scoped to a pending question, so slow calls keep the full quiet period.
    static func withHeartbeat<T>(_ id: UUID?, ask: () async throws -> T) async rethrows -> T {
        guard let id, NotificationsPreferenceStore.isEnabled, let draft = loadDraft(id) else {
            return try await ask()
        }
        let heartbeat = renewReminder(for: draft)
        defer { heartbeat.cancel() }
        return try await ask()
    }

    /// Holds the reminder `heartbeatDeadline` out until cancelled, then restores
    /// the quiet period — from in here, so a renewal in flight can't overtake it
    /// and leave a short fuse burning. touch() also clears the reminder a
    /// process suspended (not killed) past a renewal let through.
    private static func renewReminder(for draft: TransactionDraft) -> Task<Void, Error> {
        Task {
            defer { touch(draft.id) }
            while true { // exits by the sleep throwing on cancellation
                scheduleNotification(for: draft, delay: heartbeatDeadline, log: false)
                try await Task.sleep(for: .seconds(heartbeatInterval))
            }
        }
    }

    /// Runs the intent's live split question with the split quick-reply actions
    /// armed for its duration. A throwing `ask` (the dismissal those actions
    /// exist for) deliberately skips the disarm, so the intent's catch → fail()
    /// fires a reminder that still carries them.
    static func askSplitChoice(
        draftId: UUID?,
        context: TransactionDraft.PendingSplitContext,
        ask: () async throws -> SplitwiseSplitOption
    ) async rethrows -> SplitwiseSplitOption {
        guard let draftId else { return try await ask() }
        armSplitChoice(draftId, context: context)
        let choice = try await withHeartbeat(draftId, ask: ask)
        disarmSplitChoice(draftId)
        return choice
    }

    /// Poses the split question as a notification in its own right, no perform()
    /// waiting on the answer — for a background "Add" that got the transaction in
    /// but left the split to decide. Answering it completes the draft.
    static func askSplitChoiceViaNotification(_ id: UUID, context: TransactionDraft.PendingSplitContext) {
        armSplitChoice(id, context: context, delay: 1)
    }

    private static func armSplitChoice(
        _ id: UUID,
        context: TransactionDraft.PendingSplitContext,
        delay: TimeInterval = fireDelay
    ) {
        guard let draft = update(id, { $0.pendingSplitContext = context }) else { return }
        clearDelivered(id)
        scheduleNotification(for: draft, delay: delay)
    }

    /// Rescheduling is left to the touch() that follows.
    private static func disarmSplitChoice(_ id: UUID) {
        _ = update(id) { $0.pendingSplitContext = nil }
    }

    /// Re-delivers a plain reminder after a notification action couldn't finish
    /// the transaction (no friend to split with, an unparseable manual share),
    /// without the quick reply that just failed.
    static func notifyNeedsApp(_ id: UUID) {
        guard let draft = loadDraft(id) else { return }
        scheduleNotification(
            for: draft,
            delay: 1,
            body: String(localized: "\(draft.summary). Couldn't finish automatically — tap to complete in Relay."),
            splitActions: false
        )
    }

    /// Fires the reminder right away — call when perform() is about to throw,
    /// having written nothing. No-ops once it has fired, since re-adding the
    /// request re-alerts it: what a run suspended past the quiet period would do
    /// on resuming and unwinding through here.
    static func fail(_ id: UUID) async {
        guard let draft = loadDraft(id) else { return }
        guard await !hasDeliveredReminder(id) else {
            logger.log("fail: reminder already delivered for id=\(id.uuidString, privacy: .public) — not re-firing")
            return
        }
        scheduleNotification(for: draft, delay: 1)
    }

    /// Repoints a draft at a new payload, keeping its id and so its notification
    /// identifier — for a run that committed its YNAB half and now only needs the
    /// split guarded. complete() + begin() would mint a second identifier, and so
    /// a second reminder able to fire for one run.
    static func transition(_ id: UUID, to payload: TransactionDraft.Payload) {
        let updated = update(id) { $0 = TransactionDraft(id: id, startedAt: $0.startedAt, payload: payload) }
        guard let updated else { return }
        logger.log("transitioned draft id=\(id.uuidString, privacy: .public)")
        clearDelivered(id)
        scheduleNotification(for: updated)
    }

    static func complete(_ id: UUID) {
        logger.log("completing draft id=\(id.uuidString, privacy: .public)")
        save(TransactionDraftStore.load().filter { $0.id != id })
        cancelReminder(id)
    }

    // MARK: - Store

    private static func loadDraft(_ id: UUID) -> TransactionDraft? {
        TransactionDraftStore.load().first { $0.id == id }
    }

    /// Applies `change` to the stored draft, returning it as saved.
    private static func update(_ id: UUID, _ change: (inout TransactionDraft) -> Void) -> TransactionDraft? {
        var drafts = TransactionDraftStore.load()
        guard let index = drafts.firstIndex(where: { $0.id == id }) else { return nil }
        change(&drafts[index])
        save(drafts)
        return drafts[index]
    }

    private static func save(_ drafts: [TransactionDraft]) {
        do {
            try TransactionDraftStore.save(drafts)
        } catch {
            logger.error("failed to save transaction drafts: \(String(describing: error), privacy: .public)")
        }
    }

    /// Drops the oldest drafts past `DraftLimitPreferenceStore.limit`, cancelling
    /// any reminder scheduled for a dropped one.
    private static func save(trimmedToLimit drafts: [TransactionDraft]) {
        let (kept, dropped) = splitByLimit(drafts, limit: DraftLimitPreferenceStore.limit)
        dropped.forEach { cancelReminder($0.id) }
        save(kept)
    }

    // MARK: - Notifications

    private static func clearDelivered(_ id: UUID) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id.uuidString])
    }

    private static func cancelReminder(_ id: UUID) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id.uuidString])
        center.removeDeliveredNotifications(withIdentifiers: [id.uuidString])
    }

    private static func hasDeliveredReminder(_ id: UUID) async -> Bool {
        await UNUserNotificationCenter.current().deliveredNotifications()
            .contains { $0.request.identifier == id.uuidString }
    }

    /// `splitActions` nil follows the draft's armed `pendingSplitContext`, so
    /// every path carries the quick replies exactly while the split is open.
    /// `log` is off for heartbeat renewals, which re-add the same reminder.
    private static func scheduleNotification(
        for draft: TransactionDraft,
        delay: TimeInterval = fireDelay,
        title: String? = nil,
        body: String? = nil,
        categoryIdentifier: String? = nil,
        splitActions: Bool? = nil,
        log: Bool = true
    ) {
        guard NotificationsPreferenceStore.isEnabled else { return }

        let attachActions = splitActions ?? (draft.pendingSplitContext != nil)
        if log {
            logger.log("scheduling draft reminder id=\(draft.id.uuidString, privacy: .public) delay=\(delay, privacy: .public) actions=\(attachActions, privacy: .public)")
        }

        let content = attachActions
            ? splitQuestionContent(for: draft)
            : incompleteContent(for: draft, title: title, body: body, categoryIdentifier: categoryIdentifier)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        let request = UNNotificationRequest(identifier: draft.id.uuidString, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                logger.error("failed to schedule draft notification: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// YNAB is already done once the split is the open question, so nothing here
    /// is incomplete — it just offers the split.
    private static func splitQuestionContent(for draft: TransactionDraft) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.sound = .default
        content.categoryIdentifier = WalletSplitNotification.categoryIdentifier
        content.title = draft.summary
        if let friendName = draft.pendingSplitContext?.friend?.firstName {
            content.body = String(localized: "Split with \(friendName)?")
        } else {
            content.body = String(localized: "Split this expense?")
        }
        return content
    }

    private static func incompleteContent(
        for draft: TransactionDraft,
        title: String?,
        body: String?,
        categoryIdentifier: String?
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.sound = .default
        content.categoryIdentifier = categoryIdentifier ?? WalletIncompleteNotification.categoryIdentifier
        content.title = title ?? String(localized: "Transaction Incomplete")
        content.body = body ?? String(localized: "\(draft.summary). Tap to continue.")
        return content
    }
}
