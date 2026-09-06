//
//  PendingOperationQueue.swift
//  Relay
//
//  Holds YNAB transactions and ledger expenses that couldn't be sent while
//  offline until they can be retried. Drained opportunistically: on app
//  foreground, at the start of every App Intent, and manually from
//  PendingQueueView. There's no OS-level background sync (BGTaskScheduler isn't
//  set up, and wouldn't cover the macOS build anyway), so a queued item only
//  retries the next time Relay is opened or a Shortcut runs.
//
//  Two things make a stuck queue hard to miss meanwhile: the app icon badge
//  mirrors `operations.count`, and a notification fires a day after the queue
//  first goes non-empty in case it's still stuck.
//

import Foundation
import SwiftUI
import UserNotifications
import os

private nonisolated let logger = Logger(subsystem: Const.loggerSubsystem, category: "PendingOperationQueue")

@MainActor
@Observable
final class PendingOperationQueue {
    static let shared = PendingOperationQueue()

    static let reminderNotificationID = "pendingOperationQueueReminder"
    private static let reminderDelay: TimeInterval = 60 * 60 * 24

    private(set) var operations: [PendingOperation] = []
    private var isFlushing = false

    private init() {
        operations = PendingOperationQueueStore.load()
        updateBadge()
        // Re-arms the reminder in case Relay was killed before a previous schedule
        // completed. Harmless either way — the same identifier just replaces it.
        if !operations.isEmpty {
            scheduleReminderNotification()
        }
    }

    func enqueue(
        _ payload: PendingOperation.Payload,
        summary: String,
        groupId: UUID? = nil,
        merchant: String? = nil,
        recordsHistory: Bool = true
    ) {
        let wasEmpty = operations.isEmpty
        let operation = PendingOperation(
            id: UUID(),
            queuedAt: Date(),
            summary: summary,
            attemptCount: 0,
            lastError: nil,
            payload: payload,
            groupId: groupId,
            merchant: merchant,
            recordsHistory: recordsHistory
        )
        withAnimation {
            // An expense edited again before the first attempt syncs replaces
            // its own queued write rather than adding a second one for the
            // same record — they'd both save the same recordID, and the
            // stale one would win by running last.
            if let index = indexOfQueuedLedgerExpense(id: payload.ledgerExpenseID) {
                operations[index] = operation
            } else {
                operations.append(operation)
            }
        }
        persist()
        updateBadge()
        if wasEmpty {
            scheduleReminderNotification()
        }
        logger.log("queued operation: \(summary, privacy: .public)")
    }

    /// The expenses this queue is still holding, so `LedgerStore` can keep
    /// showing them on the ledger they were added to.
    var pendingLedgerExpenses: [LedgerExpenseRequest] {
        operations.compactMap {
            guard case .ledgerExpense(let expense) = $0.payload else { return nil }
            return expense
        }
    }

    func isPending(expenseID: String) -> Bool {
        indexOfQueuedLedgerExpense(id: expenseID) != nil
    }

    /// Drops the queued write for an expense that's since been deleted
    /// locally. No-op if it already synced.
    func cancelLedgerExpense(id: String) {
        guard let index = indexOfQueuedLedgerExpense(id: id) else { return }
        remove(id: operations[index].id)
    }

    private func indexOfQueuedLedgerExpense(id: String?) -> Int? {
        guard let id else { return nil }
        return operations.firstIndex { $0.payload.ledgerExpenseID == id }
    }

    /// User-initiated: abandons the write for good, which for a ledger
    /// expense also means taking the row back off the ledger it was
    /// optimistically added to.
    func delete(id: UUID) {
        if case .ledgerExpense(let expense)? = operations.first(where: { $0.id == id })?.payload {
            LedgerStore.shared.discardQueued(expenseID: expense.expenseID, zoneName: expense.zoneName)
        }
        remove(id: id)
    }

    /// Drops the operation without touching what it was going to write —
    /// what a successful sync leaves behind.
    private func remove(id: UUID) {
        withAnimation {
            operations.removeAll { $0.id == id }
        }
        persist()
        updateBadge()
        if operations.isEmpty {
            cancelReminderNotification()
        }
    }

    /// Retries every queued operation once, in submission order, pausing between
    /// calls (YNAB/Splitwise ToS: don't hammer retries). Stops early on a
    /// connectivity failure — the rest are almost certainly offline too, and this
    /// runs often enough that there'll be another pass soon.
    func flush() async {
        guard !isFlushing, !operations.isEmpty else { return }
        isFlushing = true
        defer { isFlushing = false }

        for operation in operations where operations.contains(where: { $0.id == operation.id }) {
            switch await attempt(operation) {
            case .success:
                remove(id: operation.id)
            case .failure(let message, let isConnectivity):
                update(id: operation.id, lastError: message)
                if isConnectivity { return }
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
    }

    func retryNow(id: UUID) async {
        guard let operation = operations.first(where: { $0.id == id }) else { return }
        switch await attempt(operation) {
        case .success:
            remove(id: id)
        case .failure(let message, _):
            update(id: id, lastError: message)
        }
    }

    private enum AttemptResult {
        case success
        case failure(message: String, isConnectivity: Bool)
    }

    private func attempt(_ operation: PendingOperation) async -> AttemptResult {
        do {
            switch operation.payload {
            case .ynabTransaction(let transaction):
                guard let token = await YNABAuthService.validAccessToken() else {
                    throw YNABIntentError.notAuthenticated
                }
                try await YNABService.createTransaction(transaction, token: token)
                if let categoryId = transaction.categoryId {
                    YNABCategoryUsageStore.recordUsage(categoryId: categoryId)
                }
            case .ledgerExpense(let expense):
                guard let ledger = LedgerStore.shared.ledgers.first(where: { $0.zoneName == expense.zoneName }) else {
                    throw LedgerExpenseError.validation(String(localized: "Couldn't find that ledger."))
                }
                try await LedgerService.save(expense.asExpense, in: ledger)
                LedgerParticipantUsageStore.recordUsage(participantIDs: expense.others.map(\.participantID))
            }
            if operation.shouldRecordHistory {
                TransactionHistoryStore.record(summary: operation.summary, payload: operation.payload, groupId: operation.groupId, merchant: operation.merchant)
            }
            logger.log("synced queued operation: \(operation.summary, privacy: .public)")
            return .success
        } catch {
            if error.isConnectivityFailure {
                return .failure(message: "No connection — will retry automatically.", isConnectivity: true)
            }
            return .failure(message: describe(error, for: operation.payload), isConnectivity: false)
        }
    }

    /// `message(for:)` keeps an already-typed error as-is rather than re-mapping it
    /// through `.from(_:)`, which only pattern-matches raw API errors and would
    /// lose the specific reason.
    private func describe(_ error: Error, for payload: PendingOperation.Payload) -> String {
        switch payload {
        case .ynabTransaction: YNABIntentError.message(for: error)
        // No token to invalidate and no rate limit to explain, so the error's
        // own description is already the most specific thing there is.
        case .ledgerExpense: error.localizedDescription
        }
    }

    private func update(id: UUID, lastError: String) {
        guard let index = operations.firstIndex(where: { $0.id == id }) else { return }
        operations[index].attemptCount += 1
        operations[index].lastError = lastError
        persist()
    }

    private func persist() {
        do {
            try PendingOperationQueueStore.save(operations)
        } catch {
            logger.error("failed to save pending operations: \(String(describing: error), privacy: .public)")
        }
    }

    private func updateBadge() {
        UNUserNotificationCenter.current().setBadgeCount(operations.count) { error in
            if let error {
                logger.error("failed to set badge count: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func scheduleReminderNotification() {
        guard NotificationsPreferenceStore.isEnabled else { return }

        let content = UNMutableNotificationContent()
        content.title = String(localized: "Pending Transactions")
        content.body = String(localized: "Some transactions are still waiting to sync.")
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: Self.reminderDelay, repeats: false)
        let request = UNNotificationRequest(identifier: Self.reminderNotificationID, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                logger.error("failed to schedule pending queue reminder: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func cancelReminderNotification() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.reminderNotificationID])
        center.removeDeliveredNotifications(withIdentifiers: [Self.reminderNotificationID])
    }
}
