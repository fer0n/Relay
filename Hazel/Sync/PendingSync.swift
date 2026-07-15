//
//  PendingSync.swift
//  Hazel
//
//  Shared "try now (briefly retrying on connectivity failures), otherwise
//  queue it for later" logic used by every intent that writes to YNAB or
//  Splitwise. A non-connectivity failure (bad auth, rate limit, validation)
//  is surfaced immediately instead — retrying those wouldn't help, and
//  queueing a request YNAB/Splitwise actively rejected risks it failing the
//  same way forever.
//

import Foundation

enum PendingSyncOutcome {
    case created
    case queued
}

nonisolated enum PendingSync {
    static func createYNABTransaction(
        _ transaction: YNABTransactionRequest,
        token: String,
        summary: String
    ) async throws -> PendingSyncOutcome {
        do {
            try await retryOnConnectivityFailure { try await YNABService.createTransaction(transaction, token: token) }
            return .created
        } catch {
            guard error.isConnectivityFailure else { throw YNABIntentError.from(error) }
            await PendingOperationQueue.shared.enqueue(.ynabTransaction(transaction), summary: summary)
            return .queued
        }
    }

    static func createSplitwiseExpense(
        _ expense: SplitwiseExpenseRequest,
        token: String,
        summary: String
    ) async throws -> PendingSyncOutcome {
        do {
            try await retryOnConnectivityFailure { try await SplitwiseService.createExpense(expense, token: token) }
            return .created
        } catch {
            guard error.isConnectivityFailure else { throw SplitwiseIntentError.from(error) }
            await PendingOperationQueue.shared.enqueue(.splitwiseExpense(expense), summary: summary)
            return .queued
        }
    }

    /// Retries a connectivity failure twice more with a short fixed backoff
    /// before giving up — covers a momentary blip without holding up the
    /// intent (and its Shortcuts execution time budget) for long.
    static func retryOnConnectivityFailure<T>(_ operation: () async throws -> T) async throws -> T {
        let backoffNanoseconds: [UInt64] = [1_000_000_000, 2_000_000_000]
        for delay in backoffNanoseconds {
            do {
                return try await operation()
            } catch {
                guard error.isConnectivityFailure else { throw error }
                try? await Task.sleep(nanoseconds: delay)
            }
        }
        return try await operation()
    }
}
