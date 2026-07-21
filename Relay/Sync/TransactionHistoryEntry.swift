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
//  A single wallet automation run can create both a YNAB transaction and a
//  Splitwise split; those share a `groupId` so TransactionHistoryStore
//  folds them into one entry (the YNAB transaction in `payload`, the
//  Splitwise expense in `split`) shown as one combined row and re-added
//  together, rather than as two separate entries.
//

import Foundation

struct TransactionHistoryEntry: Codable, Identifiable {
    let id: UUID
    let createdAt: Date
    let summary: String
    let payload: PendingOperation.Payload
    /// Shared by every write from the same wallet automation run, so the
    /// YNAB transaction and its Splitwise split merge into one entry rather
    /// than showing up as two. Nil for standalone (non-wallet) writes.
    var groupId: UUID?
    /// Set when this entry's YNAB transaction (`payload`) was created
    /// alongside a Splitwise split in the same run — the two are shown as
    /// one combined row and re-added together.
    var split: Split?

    struct Split: Codable {
        let summary: String
        let expense: SplitwiseExpenseRequest
    }

    var service: TransactionService {
        switch payload {
        case .ynabTransaction: .ynab
        case .splitwiseExpense: .splitwise
        }
    }

    /// The second service icon/name shown for a combined YNAB+Splitwise
    /// entry — nil for a plain single-service entry.
    var secondaryService: TransactionService? {
        split == nil ? nil : .splitwise
    }

    /// Payee (YNAB) or description (Splitwise).
    var title: String { payload.title }

    var formattedAmount: String { payload.formattedAmount }

    /// The row's "· detail" suffix: the YNAB category and, for a combined
    /// entry, the friend's split share too.
    var detail: String? {
        guard let split else { return payload.detail }
        let splitDetail = PendingOperation.Payload.splitwiseExpense(split.expense).detail
        let combined = [payload.detail, splitDetail].compactMap { $0 }.joined(separator: " · ")
        return combined.isEmpty ? nil : combined
    }
}

extension TransactionHistoryEntry {
    /// YNAB category name for the primary transaction, resolved from the
    /// local cache. Nil for a Splitwise-only entry, if no category was set,
    /// or if nothing's cached yet.
    var categoryName: String? {
        guard case .ynabTransaction(let transaction) = payload,
              let categoryId = transaction.categoryId else { return nil }
        return YNABCategoryCacheStore.load()?.first { $0.id == categoryId }?.name
    }

    /// YNAB account name for the primary transaction, resolved from the
    /// local cache. Nil for a Splitwise-only entry or if uncached.
    var accountName: String? {
        guard case .ynabTransaction(let transaction) = payload else { return nil }
        return YNABAccountCacheStore.load()?.first { $0.id == transaction.accountId }?.name
    }

    /// The Splitwise friend and their share, e.g. "Alex: 12.00 €" — drawn
    /// from the combined entry's `split` or a Splitwise-only entry's
    /// `payload`. Nil for a YNAB-only entry or if the friend isn't cached.
    var splitSummary: String? {
        let request: SplitwiseExpenseRequest
        if let split {
            request = split.expense
        } else if case .splitwiseExpense(let expense) = payload {
            request = expense
        } else {
            return nil
        }
        guard let friend = SplitwiseFriendCacheStore.load()?.first(where: { $0.id == request.friendUserId }) else { return nil }
        let share = (Double(request.friendOwedCents) / 100).formatted(.currency(code: request.currencyCode))
        return "\(friend.firstName): \(share)"
    }
}

extension TransactionHistoryEntry {
    /// Resubmits this entry as a brand-new transaction/expense dated today
    /// (Splitwise: "now") — the "Re-add" action on ContentView's recent
    /// transactions list. Mirrors AddYNABTransactionIntent/AddSplitwiseExpenseIntent's
    /// token lookup and error handling. A combined wallet entry re-adds both
    /// its YNAB transaction and Splitwise split under a fresh shared group
    /// so they fold back into a single history entry.
    func readd() async throws -> PendingSyncOutcome {
        switch payload {
        case .ynabTransaction(let transaction):
            guard let token = await YNABAuthService.validAccessToken() else {
                throw YNABIntentError.notAuthenticated
            }
            let groupId = split == nil ? nil : UUID()
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
            let ynabOutcome = try await PendingSync.createYNABTransaction(resubmitted, token: token, summary: summary, groupId: groupId)
            guard let split else { return ynabOutcome }

            guard let splitwiseToken = SplitwiseAuthService.currentAccessToken else {
                // YNAB re-added, but Splitwise is no longer connected — the
                // split can't be recreated, so report the YNAB outcome.
                return ynabOutcome
            }
            let resubmittedExpense = SplitwiseExpenseRequest(
                costCents: split.expense.costCents,
                description: split.expense.description,
                currencyCode: split.expense.currencyCode,
                payerUserId: split.expense.payerUserId,
                payerOwedCents: split.expense.payerOwedCents,
                friendUserId: split.expense.friendUserId,
                friendOwedCents: split.expense.friendOwedCents,
                date: nil
            )
            let splitOutcome = try await PendingSync.createSplitwiseExpense(resubmittedExpense, token: splitwiseToken, summary: split.summary, groupId: groupId)
            if case .queued = ynabOutcome { return .queued }
            if case .queued = splitOutcome { return .queued }
            return .created
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
