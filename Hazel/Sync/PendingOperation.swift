//
//  PendingOperation.swift
//  Hazel
//
//  A YNAB transaction or Splitwise expense that couldn't be sent because the
//  device was offline, waiting in PendingOperationQueue to be retried.
//

import Foundation

struct PendingOperation: Codable, Identifiable {
    let id: UUID
    let queuedAt: Date
    /// Human-readable description shown in PendingQueueView, e.g. "12.34 at
    /// Starbucks" — built by the caller at queue time since it has the
    /// friendly names (payee, friend first name) the raw payload doesn't.
    let summary: String
    var attemptCount: Int
    var lastError: String?
    let payload: Payload

    enum Payload: Codable {
        case ynabTransaction(YNABTransactionRequest)
        case splitwiseExpense(SplitwiseExpenseRequest)
    }

    enum Service {
        case ynab
        case splitwise
    }

    var service: Service {
        switch payload {
        case .ynabTransaction: .ynab
        case .splitwiseExpense: .splitwise
        }
    }
}
