//
//  SplitwiseExpense.swift
//  Relay
//
//  Codable models for `get_expenses` (https://dev.splitwise.com) — the
//  actual expense history shared with a friend, as opposed to
//  SplitwiseModels.swift's SplitwiseExpenseRequest (the one-way "create an
//  expense" payload Relay sends). Backs ContentView's default-friend balance
//  card and SplitwiseFriendTransactionsView's transaction list.
//

import Foundation

struct SplitwiseExpenseUser: Codable {
    let userId: Int
    let paidShare: String
    let netBalance: String

    /// What this user actually paid toward the expense.
    var paid: Double? { Double(paidShare) }

    /// This user's portion of the expense — the share they're responsible
    /// for. Splitwise gives net_balance = paid_share - owed_share, so the
    /// owed share is paid_share - net_balance.
    var owedShare: Double? {
        guard let paid = Double(paidShare), let net = Double(netBalance) else { return nil }
        return paid - net
    }
}

struct SplitwiseExpense: Codable, Identifiable {
    let id: Int
    let description: String
    let cost: String
    let currencyCode: String
    let date: Date
    let deletedAt: Date?
    let users: [SplitwiseExpenseUser]
}

struct SplitwiseExpensesResponse: Codable {
    let expenses: [SplitwiseExpense]
}

extension SplitwiseExpense {
    /// This device's signed share of the expense — positive if the signed-in
    /// Splitwise user is owed, negative if they owe — resolved against
    /// SplitwiseCurrentUserStore's cached user id. Nil if that's not cached
    /// yet, in which case callers fall back to showing the plain (unsigned)
    /// `cost`.
    var currentUserNetBalance: Double? {
        guard let userId = SplitwiseCurrentUserStore.load()?.id,
              let entry = users.first(where: { $0.userId == userId }),
              let value = Double(entry.netBalance) else { return nil }
        return value
    }

    /// The row/detail subheader: "You paid 25 €" if the signed-in user
    /// covered the cost, otherwise "<friendName> paid 25 €". Splitwise
    /// expenses fetched here are always between the signed-in user and
    /// exactly one friend (see SplitwiseFriendTransactionsView), so whoever
    /// isn't "you" is assumed to be that friend rather than re-deriving
    /// their name from `users`. Nil if the signed-in user's id isn't cached
    /// yet.
    func payerDescription(friendName: String) -> String? {
        guard let userId = SplitwiseCurrentUserStore.load()?.id,
              let entry = users.first(where: { $0.userId == userId }),
              let ownPaidShare = Double(entry.paidShare) else { return nil }

        if ownPaidShare > 0 {
            return "You paid \(ownPaidShare.formatted(.currency(code: currencyCode)))"
        }
        // Whoever actually paid (other than the signed-in user) — usually
        // the friend this list is for, but falls back to the plain cost if
        // no one else shows a paid share (e.g. an even group split).
        guard let payer = users.first(where: { $0.userId != userId && (Double($0.paidShare) ?? 0) > 0 }),
              let payerPaidShare = Double(payer.paidShare) else {
            return "\(friendName) paid"
        }
        return "\(friendName) paid \(payerPaidShare.formatted(.currency(code: currencyCode)))"
    }

    /// One participant's portion of the expense, for the detail view's split
    /// breakdown — labeled "You" for the signed-in user and `friendName` for
    /// everyone else (these expenses are 1:1 with a friend). Reused for both
    /// the owed-share rows and the paid rows.
    struct Share: Identifiable {
        let id: Int
        let name: String
        let amount: Double
    }

    /// How the cost is split, one entry per participant, e.g. "You: 12.50 €",
    /// "Kim: 12.50 €". `friendName` labels whoever isn't the signed-in user.
    func shareBreakdown(friendName: String) -> [Share] {
        let currentUserId = SplitwiseCurrentUserStore.load()?.id
        return users.compactMap { user in
            guard let owed = user.owedShare else { return nil }
            let name = user.userId == currentUserId ? "You" : friendName
            return Share(id: user.userId, name: name, amount: owed)
        }
    }

    /// Who fronted how much, for the detail view's split breakdown — omits
    /// participants with a zero paid share, since the typical case is one
    /// person paying the full cost and everyone else paying nothing.
    func paidBreakdown(friendName: String) -> [Share] {
        let currentUserId = SplitwiseCurrentUserStore.load()?.id
        return users.compactMap { user in
            guard let paid = user.paid, paid > 0 else { return nil }
            let name = user.userId == currentUserId ? "You" : friendName
            return Share(id: user.userId, name: name, amount: paid)
        }
    }

    /// Who fronted the cost, labeled for the detail view's "Paid by" row —
    /// "You" if the signed-in user paid, otherwise `friendName`. Nil if the
    /// signed-in user's id isn't cached yet or no one shows a paid share.
    func payerName(friendName: String) -> String? {
        guard let currentUserId = SplitwiseCurrentUserStore.load()?.id else { return nil }
        guard let payer = users.first(where: { ($0.paid ?? 0) > 0 }) else { return nil }
        return payer.userId == currentUserId ? "You" : friendName
    }
}
