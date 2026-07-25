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
    /// The Shortcuts-supplied merchant string this entry resolved from, when
    /// created by a wallet automation run rather than a manual/re-add entry.
    /// Nil for those, and for any entry recorded before this field existed
    /// (Optional decodes to nil for a missing key, no tolerant init needed).
    /// Lets the confirmation detail view resolve the current Payee/Template
    /// mapping for this merchant and write an edited payee back to
    /// WalletTransactionConfig.
    var merchant: String?
    /// Later runs recognised as this same purchase arriving through a
    /// second automation (Wallet vs. a bank notification) and therefore not
    /// written — see TransactionClaim. They collapse into this entry rather
    /// than becoming rows of their own, so re-adding this row is also the
    /// "actually, add it anyway" escape hatch if a match was wrong.
    ///
    /// Non-optional with a default, which means the synthesized decoder
    /// throws `keyNotFound` on entries written before this field existed and
    /// `TransactionHistoryStore.load()` starts empty — a deliberate one-time
    /// reset of at most `historyLimit` rows of re-add shortcuts, not worth a
    /// tolerant decoder. (`WalletTransactionConfig` is the opposite case: it
    /// holds mappings built up over months and does need one.)
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
        let share = (Double(request.friendOwedCents) / Const.centsPerUnit).formatted(.currency(code: request.currencyCode))
        return "\(friend.firstName): \(share)"
    }
}
