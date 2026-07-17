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

    var service: TransactionService {
        switch payload {
        case .ynabTransaction: .ynab
        case .splitwiseExpense: .splitwise
        }
    }
}

extension PendingOperation.Payload {
    /// Payee (YNAB) or description (Splitwise) — TransactionSummaryRow's title.
    var title: String {
        switch self {
        case .ynabTransaction(let transaction): transaction.payeeName
        case .splitwiseExpense(let expense): expense.description
        }
    }

    /// YNAB's real signed amount, or Splitwise's total expense cost (not the
    /// signed-in user's own share) — formatted for TransactionSummaryRow.
    var formattedAmount: String {
        switch self {
        case .ynabTransaction(let transaction):
            (Double(transaction.amount) / 1000).asMoneyString
        case .splitwiseExpense(let expense):
            // Splitwise's cost has no sign of its own (it's just "how much
            // did this cost"), but the signed-in user always pays the full
            // amount upfront — same outflow as a YNAB expense — so negate
            // it to match YNAB's negative-for-money-out convention.
            (-Double(expense.costCents) / 100).asMoneyString
        }
    }

    /// Category name (YNAB), or the friend's name and their share of the
    /// cost, e.g. "Alex: 12.00 €" (Splitwise) — resolved from the locally
    /// cached category/friend list. Nil if nothing's cached yet or no
    /// category was set.
    var detail: String? {
        switch self {
        case .ynabTransaction(let transaction):
            guard let categoryId = transaction.categoryId else { return nil }
            return YNABCategoryCacheStore.load()?.first { $0.id == categoryId }?.name
        case .splitwiseExpense(let expense):
            guard let friend = SplitwiseFriendCacheStore.load()?.first(where: { $0.id == expense.friendUserId }) else { return nil }
            let share = (Double(expense.friendOwedCents) / 100).formatted(.currency(code: expense.currencyCode))
            return "\(friend.firstName): \(share)"
        }
    }
}
