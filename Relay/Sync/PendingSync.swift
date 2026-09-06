//
//  PendingSync.swift
//  Relay
//
//  Shared "try now (briefly retrying on connectivity failures), otherwise
//  queue it for later" logic for writes to YNAB. A non-connectivity failure
//  (bad auth, rate limit, validation) is surfaced immediately instead —
//  retrying those wouldn't help, and queueing a request YNAB actively
//  rejected risks it failing the same way forever.
//
//  Ledger writes queue too, but from `LedgerStore.save` rather than here:
//  every path into a ledger goes through it, it already holds the optimistic
//  row the queued expense keeps showing as, and a CloudKit write has no
//  token to refresh or rate limit to interpret on the way.
//

import Foundation

nonisolated enum PendingSyncOutcome: Equatable {
    case created
    case queued
}

nonisolated enum PendingSync {
    /// `groupId`, when set, is shared with the sibling write from the same
    /// wallet automation run so the two fold into one combined history entry.
    static func createYNABTransaction(
        _ transaction: YNABTransactionRequest,
        token: String,
        summary: String,
        groupId: UUID? = nil,
        merchant: String? = nil
    ) async throws -> PendingSyncOutcome {
        do {
            try await retryOnConnectivityFailure { try await YNABService.createTransaction(transaction, token: token) }
            TransactionHistoryStore.record(summary: summary, payload: .ynabTransaction(transaction), groupId: groupId, merchant: merchant)
            return .created
        } catch {
            guard error.isConnectivityFailure else { throw YNABIntentError.from(error) }
            await PendingOperationQueue.shared.enqueue(.ynabTransaction(transaction), summary: summary, groupId: groupId, merchant: merchant)
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
