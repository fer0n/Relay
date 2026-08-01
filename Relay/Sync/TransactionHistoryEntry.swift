//
//  TransactionHistoryEntry.swift
//  Relay
//
//  A YNAB transaction or Splitwise expense that was actually created, so
//  ContentView can offer the last few as a quick "re-add". Reuses
//  PendingOperation's payload/service shape, being the same request data.
//
//  One wallet run can create both a YNAB transaction and a Splitwise split;
//  those share a `groupId` so TransactionHistoryStore folds them into a single
//  entry, shown as one row and re-added together.
//

import Foundation

nonisolated struct TransactionHistoryEntry: Codable, Identifiable {
    let id: UUID
    let createdAt: Date
    let summary: String
    let payload: PendingOperation.Payload
    /// Shared by every write from the same run; nil for standalone writes.
    var groupId: UUID?
    /// The Splitwise split created alongside this entry's YNAB transaction.
    var split: Split?
    /// The Shortcuts-supplied merchant string this entry resolved from; nil for a
    /// manual/re-add entry. Shown under the amount in the detail view — the one
    /// place it appears, deliberately not in the summary rows — which also uses it
    /// to resolve and edit the merchant's Payee/Template mapping.
    var merchant: String?
    /// Later runs dropped as duplicates of this one — see TransactionClaim. They
    /// collapse into this entry rather than becoming rows of their own, so
    /// re-adding is the "add it anyway" escape hatch when a match was wrong.
    ///
    /// Non-optional with a default, so the synthesized decoder throws
    /// `keyNotFound` on older entries and history starts empty. A deliberate
    /// one-time reset of at most `historyLimit` re-add shortcuts, not worth a
    /// tolerant decoder — unlike `WalletTransactionConfig`, which holds mappings
    /// built up over months.
    var suppressed: [SuppressedRun] = []

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

    /// Nil for a plain single-service entry.
    var secondaryService: TransactionService? {
        split == nil ? nil : .splitwise
    }

    /// Payee (YNAB) or description (Splitwise).
    var title: String { payload.title }

    var formattedAmount: String { payload.formattedAmount }

    /// The row's "· detail" suffix.
    var detail: String? {
        guard let split else { return payload.detail }
        let splitDetail = PendingOperation.Payload.splitwiseExpense(split.expense).detail
        let combined = [payload.detail, splitDetail].compactMap { $0 }.joined(separator: " · ")
        return combined.isEmpty ? nil : combined
    }
}

nonisolated extension TransactionHistoryEntry {
    /// Resolved from the local cache, so nil until something's cached.
    var categoryName: String? {
        guard case .ynabTransaction(let transaction) = payload,
              let categoryId = transaction.categoryId else { return nil }
        return YNABCategoryCacheStore.load()?.first { $0.id == categoryId }?.name
    }

    /// Resolved from the local cache, so nil until something's cached.
    var accountName: String? {
        guard case .ynabTransaction(let transaction) = payload else { return nil }
        return YNABAccountCacheStore.load()?.first { $0.id == transaction.accountId }?.name
    }

    /// The friend and their share, e.g. "Alex: 12.00 €". Nil for a YNAB-only entry
    /// or while the friend isn't cached.
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
        let share = (Double(request.friendOwedCents) / Const.centsPerUnit).formatted(.currency(code: request.currencyCode))
        return "\(friend.firstName): \(share)"
    }
}
