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

    @discardableResult
    static func begin(_ payload: TransactionDraft.Payload) -> UUID {
        let draft = create(payload)
        scheduleNotification(for: draft)
        return draft.id
    }

    /// For a purchase Relay deliberately won't add on its own, because the
    /// automation has "Require Confirmation" set — so the reminder asks for
    /// approval rather than nudging. Kept at the usual quiet-period delay,
    /// which doubles as a grace window for the other automation to arrive and
    /// supersede it (see TransactionClaim.supersededConfirmations).
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

    /// A draft whose reminder is the split question itself. On the Splitwise
    /// path that question doubles as the confirmation, since "Don't Split"
    /// means nothing gets created at all.
    @discardableResult
    static func beginAwaitingSplitChoice(
        _ payload: TransactionDraft.Payload,
        context: TransactionDraft.PendingSplitContext
    ) -> UUID {
        let draft = create(payload, context: context)
        scheduleNotification(for: draft)
        return draft.id
    }

    /// Starts — or takes over — a draft for a merchant with no template yet,
    /// since setting one up belongs in Relay's form rather than a chain of
    /// Shortcuts prompts.
    ///
    /// `existing` is the draft the run's "Ensure Completion" guard already
    /// began, reused rather than completed-and-replaced so the whole run stays
    /// in a single reminder slot.
    ///
    /// Kept at the usual quiet-period delay, unlike `fail()`: the intent asks
    /// to continue in the foreground straight after this, so the reminder is
    /// only the fallback for that being declined or impossible.
    @discardableResult
    static func beginNeedsTemplate(_ payload: TransactionDraft.Payload, existing: UUID?) -> UUID {
        let draft = existing.flatMap { id in TransactionDraftStore.load().first { $0.id == id } }
            ?? create(payload)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [draft.id.uuidString])
        scheduleNotification(for: draft)
        return draft.id
    }

    private static func create(
        _ payload: TransactionDraft.Payload,
        context: TransactionDraft.PendingSplitContext? = nil
    ) -> TransactionDraft {
        var draft = TransactionDraft(id: UUID(), startedAt: Date(), payload: payload)
        draft.pendingSplitContext = context
        var drafts = TransactionDraftStore.load()
        drafts.append(draft)
        save(trimmedToLimit: drafts)
        return draft
    }

    /// Ordered by `startedAt`, not insertion order, since `transition(_:to:)`
    /// keeps a draft's original id/startedAt rather than re-adding it. Pure, so
    /// tests exercise the limit rule directly.
    static func splitByLimit(_ drafts: [TransactionDraft], limit: Int) -> (kept: [TransactionDraft], dropped: [TransactionDraft]) {
        guard drafts.count > limit else { return (drafts, []) }
        let sorted = drafts.sorted { $0.startedAt > $1.startedAt }
        return (Array(sorted.prefix(limit)), Array(sorted[limit...]))
    }

    /// Drops the oldest drafts past `DraftLimitPreferenceStore.limit`, cancelling
    /// any reminder scheduled for a dropped one.
    private static func save(trimmedToLimit drafts: [TransactionDraft]) {
        let (kept, dropped) = splitByLimit(drafts, limit: DraftLimitPreferenceStore.limit)
        if !dropped.isEmpty {
            let identifiers = dropped.map(\.id.uuidString)
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: identifiers)
            center.removeDeliveredNotifications(withIdentifiers: identifiers)
        }
        do {
            try TransactionDraftStore.save(kept)
        } catch {
            logger.error("failed to save transaction draft: \(String(describing: error), privacy: .public)")
        }
    }

    /// Called when Settings disappears, not on every picker change, so a lower
    /// value can be dialed back up before it discards anything.
    static func enforceLimit() {
        save(trimmedToLimit: TransactionDraftStore.load())
    }

    /// Pushes the reminder deadline back out — call after every follow-up
    /// question is answered. Re-adding a request with the same identifier
    /// replaces the pending one, and the explicit removal clears an
    /// already-delivered copy, so no stale reminder outlives a progressing run.
    static func touch(_ id: UUID) {
        guard let draft = TransactionDraftStore.load().first(where: { $0.id == id }) else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id.uuidString])
        scheduleNotification(for: draft)
    }

    /// Runs the intent's live split question with the split quick-reply actions
    /// armed on `draftId` for its duration. Pairing arm and disarm here keeps
    /// the one subtlety intact: if `ask` throws (the prompt was dismissed —
    /// exactly what the quick reply is for), the context stays armed so the
    /// intent's catch → fail() fires a reminder that still carries the actions.
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

    /// Poses the split question as a notification in its own right, with no
    /// perform() waiting on the answer — for a background "Add" that got the
    /// transaction in but left the split to decide. Nothing to disarm: the
    /// reminder *is* the question, and answering it completes the draft.
    static func askSplitChoiceViaNotification(_ id: UUID, context: TransactionDraft.PendingSplitContext) {
        armSplitChoice(id, context: context, delay: 1)
    }

    private static func armSplitChoice(
        _ id: UUID,
        context: TransactionDraft.PendingSplitContext,
        delay: TimeInterval = fireDelay
    ) {
        var drafts = TransactionDraftStore.load()
        guard let index = drafts.firstIndex(where: { $0.id == id }) else { return }
        drafts[index].pendingSplitContext = context
        do {
            try TransactionDraftStore.save(drafts)
        } catch {
            logger.error("failed to save split context on draft: \(String(describing: error), privacy: .public)")
        }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id.uuidString])
        scheduleNotification(for: drafts[index], delay: delay)
    }

    /// Rescheduling is left to the touch() that immediately follows.
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

    /// Re-delivers a plain reminder after a notification action couldn't finish
    /// the transaction (no friend to split with, an unparseable manual share).
    /// Drops the split actions so the user isn't offered a quick reply that
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

    /// Fires the reminder right away — call when perform() is about to throw,
    /// since the run has definitively ended without writing anything.
    ///
    /// Unless the reminder has already fired: re-adding the request re-alerts
    /// the same notification. That happens when a background run suspends past
    /// the quiet period, then resumes and unwinds through here as the app is
    /// opened — which is exactly the duplicate the user would see.
    static func fail(_ id: UUID) async {
        guard let draft = TransactionDraftStore.load().first(where: { $0.id == id }) else { return }
        let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
        guard !delivered.contains(where: { $0.request.identifier == id.uuidString }) else {
            logger.log("fail: reminder already delivered for id=\(id.uuidString, privacy: .public) — not re-firing")
            return
        }
        scheduleNotification(for: draft, delay: 1)
    }

    /// Repoints a draft at a new payload while keeping its id, and therefore its
    /// notification identifier — used when a run commits its YNAB half and the
    /// guard should protect only the remaining split. Reusing the id (rather
    /// than complete() + begin(), which mint a second identifier) keeps the run
    /// to a single reminder slot, since same-identifier scheduling replaces.
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
        // The reminder may or may not have fired already; clear both ways.
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id.uuidString])
        center.removeDeliveredNotifications(withIdentifiers: [id.uuidString])
    }

    /// `splitActions` nil follows the draft's armed `pendingSplitContext`, so
    /// every scheduling path keeps the quick-reply actions exactly while the
    /// split is the open question.
    private static func scheduleNotification(
        for draft: TransactionDraft,
        delay: TimeInterval = fireDelay,
        title: String? = nil,
        body: String? = nil,
        categoryIdentifier: String? = nil,
        splitActions: Bool? = nil
    ) {
        guard NotificationsPreferenceStore.isEnabled else { return }

        let attachActions = splitActions ?? (draft.pendingSplitContext != nil)
        logger.log("scheduling draft reminder id=\(draft.id.uuidString, privacy: .public) delay=\(delay, privacy: .public) actions=\(attachActions, privacy: .public)")

        let content = UNMutableNotificationContent()
        content.sound = .default
        if attachActions {
            // YNAB is already done, so this isn't "incomplete" — it just offers
            // the optional split.
            content.categoryIdentifier = WalletSplitNotification.categoryIdentifier
            content.title = draft.summary
            if let friendName = draft.pendingSplitContext?.friend?.firstName {
                content.body = String(localized: "Split with \(friendName)?")
            } else {
                content.body = String(localized: "Split this expense?")
            }
        } else {
            content.categoryIdentifier = categoryIdentifier ?? WalletIncompleteNotification.categoryIdentifier
            content.title = title ?? String(localized: "Transaction Incomplete")
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
