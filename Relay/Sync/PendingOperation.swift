//
//  PendingOperation.swift
//  Relay
//
//  A YNAB transaction or ledger expense that couldn't be sent because the
//  device was offline, waiting in PendingOperationQueue to be retried.
//

import Foundation

nonisolated struct PendingOperation: Codable, Identifiable {
    let id: UUID
    let queuedAt: Date
    /// Human-readable description shown in PendingQueueView, e.g. "12.34 at
    /// Starbucks" — built by the caller at queue time since it has the
    /// friendly names (payee, friend first name) the raw payload doesn't.
    let summary: String
    var attemptCount: Int
    var lastError: String?
    let payload: Payload
    /// Shared with the sibling write from the same wallet automation run, so
    /// that once both queued items sync they fold into one combined history
    /// entry. Nil for standalone writes. Optional decoding keeps operations
    /// queued before this field existed loadable.
    var groupId: UUID?
    /// The Shortcuts-supplied merchant string, carried through to
    /// TransactionHistoryStore.record once this syncs — see
    /// TransactionHistoryEntry.merchant. Nil for standalone writes.
    var merchant: String? = nil
    /// Whether syncing this should add a "Recent" entry. False for a write
    /// that wouldn't have recorded one online either — a settlement, or an
    /// edit to an expense whose creation is already in history. Optional so
    /// operations queued before this field existed still decode, and nil
    /// reads as true: back then every queued write was one that records.
    var recordsHistory: Bool? = nil

    /// See `recordsHistory`.
    var shouldRecordHistory: Bool { recordsHistory ?? true }

    /// Swift's synthesized enum Codable is strict about the case name, so a
    /// case can be *added* freely (older payloads still decode) but never
    /// renamed or removed — a file containing an unknown case fails as a
    /// whole, not one entry.
    enum Payload: Codable {
        case ynabTransaction(YNABTransactionRequest)
        case ledgerExpense(LedgerExpenseRequest)
    }

    var service: TransactionService {
        switch payload {
        case .ynabTransaction: .ynab
        case .ledgerExpense: .ledger
        }
    }
}

nonisolated extension PendingOperation.Payload {
    /// The ledger record this write targets, so the queue can recognise a
    /// second write to the same expense. Nil for a YNAB transaction, which
    /// has no id until YNAB mints one.
    var ledgerExpenseID: String? {
        switch self {
        case .ynabTransaction: nil
        case .ledgerExpense(let expense): expense.expenseID
        }
    }

    /// Payee (YNAB) or description (a split) — TransactionSummaryRow's title.
    var title: String {
        switch self {
        case .ynabTransaction(let transaction): transaction.payeeName
        case .ledgerExpense(let expense): expense.title
        }
    }

    /// A copy with the payee (YNAB) or description (a split) replaced —
    /// used to rename a frozen TransactionHistoryEntry to match an edited
    /// Payee mapping.
    func withTitle(_ title: String) -> PendingOperation.Payload {
        switch self {
        case .ynabTransaction(let transaction):
            .ynabTransaction(YNABTransactionRequest(
                accountId: transaction.accountId,
                date: transaction.date,
                amount: transaction.amount,
                payeeName: title,
                categoryId: transaction.categoryId,
                memo: transaction.memo,
                cleared: transaction.cleared,
                approved: transaction.approved,
                importId: transaction.importId
            ))
        case .ledgerExpense(let expense):
            .ledgerExpense(expense.withTitle(title))
        }
    }

    var formattedAmount: String {
        switch self {
        case .ynabTransaction(let transaction):
            abs(Double(transaction.amount) / Const.milliunitsPerUnit).asMoneyString
        case .ledgerExpense(let expense):
            (Double(expense.costCents) / Const.centsPerUnit).asMoneyString
        }
    }

    /// Category name (YNAB), resolved from the locally cached category list,
    /// or who a split is with and their share of the cost, e.g. "Alex: 12.00 €".
    /// Nil if nothing's cached yet or no category was set.
    var detail: String? {
        switch self {
        case .ynabTransaction(let transaction):
            guard let categoryId = transaction.categoryId else { return nil }
            return YNABCategoryCacheStore.load()?.first { $0.id == categoryId }?.name
        case .ledgerExpense(let expense):
            return expense.participantsShareSummary
        }
    }
}
