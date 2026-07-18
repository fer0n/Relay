//
//  TransactionHistoryEntry.swift
//  Relay
//
//  A YNAB transaction or Splitwise expense that was actually created,
//  recorded by PendingSync (immediate creates) and PendingOperationQueue
//  (synced-after-being-queued creates) so ContentView can show the last few
//  as a quick "re-add" shortcut. Reuses PendingOperation's payload/service
//  shape since it's the exact same YNAB/Splitwise request data.
//

import Foundation

struct TransactionHistoryEntry: Codable, Identifiable {
    let id: UUID
    let createdAt: Date
    let summary: String
    let payload: PendingOperation.Payload

    var service: TransactionService {
        switch payload {
        case .ynabTransaction: .ynab
        case .splitwiseExpense: .splitwise
        }
    }
}

extension TransactionHistoryEntry {
    /// Resubmits this entry as a brand-new transaction/expense dated today
    /// (Splitwise: "now") — the "Re-add" action on ContentView's recent
    /// transactions list. Mirrors AddYNABTransactionIntent/AddSplitwiseExpenseIntent's
    /// token lookup and error handling.
    func readd() async throws -> PendingSyncOutcome {
        switch payload {
        case .ynabTransaction(let transaction):
            guard let token = await YNABAuthService.validAccessToken() else {
                throw YNABIntentError.notAuthenticated
            }
            let resubmitted = YNABTransactionRequest(
                accountId: transaction.accountId,
                date: YNABService.todayDateString(),
                amount: transaction.amount,
                payeeName: transaction.payeeName,
                categoryId: transaction.categoryId,
                memo: transaction.memo,
                cleared: transaction.cleared,
                approved: transaction.approved
            )
            return try await PendingSync.createYNABTransaction(resubmitted, token: token, summary: summary)
        case .splitwiseExpense(let expense):
            guard let token = SplitwiseAuthService.currentAccessToken else {
                throw SplitwiseIntentError.notAuthenticated
            }
            let resubmitted = SplitwiseExpenseRequest(
                costCents: expense.costCents,
                description: expense.description,
                currencyCode: expense.currencyCode,
                payerUserId: expense.payerUserId,
                payerOwedCents: expense.payerOwedCents,
                friendUserId: expense.friendUserId,
                friendOwedCents: expense.friendOwedCents,
                date: nil
            )
            return try await PendingSync.createSplitwiseExpense(resubmitted, token: token, summary: summary)
        }
    }
}
