//
//  PendingOperationQueue.swift
//  Hazel
//
//  Holds YNAB transactions / Splitwise expenses that couldn't be sent while
//  offline (queued by PendingSync) until they can be retried. Drained
//  opportunistically — on app foreground (ContentView) and at the start of
//  every App Intent (see PendingSync) — plus manually from PendingQueueView.
//  There's no true OS-level background sync (BGTaskScheduler isn't set up,
//  and wouldn't cover the native-macOS build of this app anyway), so a
//  queued item only retries the next time Hazel is opened or a Shortcut runs.
//

import Foundation
import os

private let logger = Logger(subsystem: "com.pentlandFirth.Hazel", category: "PendingOperationQueue")

@MainActor
@Observable
final class PendingOperationQueue {
    static let shared = PendingOperationQueue()

    private(set) var operations: [PendingOperation] = []
    private var isFlushing = false

    private init() {
        operations = PendingOperationQueueStore.load()
    }

    func enqueue(_ payload: PendingOperation.Payload, summary: String) {
        operations.append(
            PendingOperation(id: UUID(), queuedAt: Date(), summary: summary, attemptCount: 0, lastError: nil, payload: payload)
        )
        persist()
        logger.log("queued operation: \(summary, privacy: .public)")
    }

    func delete(id: UUID) {
        operations.removeAll { $0.id == id }
        persist()
    }

    /// Retries every queued operation once, in submission order, pausing
    /// briefly between calls (YNAB/Splitwise ToS: don't hammer retries).
    /// Stops the pass early on a connectivity failure — the rest are almost
    /// certainly offline too, and since this runs opportunistically there'll
    /// be another pass soon.
    func flush() async {
        guard !isFlushing, !operations.isEmpty else { return }
        isFlushing = true
        defer { isFlushing = false }

        for operation in operations where operations.contains(where: { $0.id == operation.id }) {
            switch await attempt(operation) {
            case .success:
                delete(id: operation.id)
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
            delete(id: id)
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
            case .splitwiseExpense(let expense):
                guard let token = SplitwiseAuthService.currentAccessToken else {
                    throw SplitwiseIntentError.notAuthenticated
                }
                try await SplitwiseService.createExpense(expense, token: token)
                SplitwiseFriendUsageStore.recordUsage(friendId: expense.friendUserId)
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

    /// `error` here can already be a YNABIntentError/SplitwiseIntentError
    /// (thrown directly above for the "no token" case) — re-mapping those
    /// through `.from(_:)` would lose the specific reason, since `.from`
    /// only pattern-matches the raw API error types.
    private func describe(_ error: Error, for payload: PendingOperation.Payload) -> String {
        switch payload {
        case .ynabTransaction:
            let intentError = (error as? YNABIntentError) ?? YNABIntentError.from(error)
            return String(localized: intentError.localizedStringResource)
        case .splitwiseExpense:
            let intentError = (error as? SplitwiseIntentError) ?? SplitwiseIntentError.from(error)
            return String(localized: intentError.localizedStringResource)
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
}
