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

nonisolated struct SplitwiseExpenseUser: Codable {
    let userId: Int
    let paidShare: String
    let netBalance: String
    /// This participant's own identity, as Splitwise nests it per-entry in
    /// `get_expenses` (`user.first_name`/`last_name`). Optional so a cache
    /// file written before this field existed still decodes (see
    /// SplitwiseExpenseCacheStore) — callers fall back to `friendName` when
    /// nil rather than failing to show a name at all.
    let user: SplitwiseExpenseParticipant?

    /// What this user actually paid toward the expense.
    var paid: Double? { Double(paidShare) }

    /// This user's portion of the expense — the share they're responsible
    /// for. Splitwise gives net_balance = paid_share - owed_share, so the
    /// owed share is paid_share - net_balance.
    var owedShare: Double? {
        guard let paid = Double(paidShare), let net = Double(netBalance) else { return nil }
        return paid - net
    }

    /// This participant's own name if Splitwise provided one, otherwise
    /// `fallback`. Expenses aren't always 1:1 with a single friend — a
    /// shared group expense (e.g. you, dom, kim) has more than one non-"You"
    /// participant, so reusing the single `friendName` for all of them would
    /// collapse dom and kim onto the same label. Resolving each user's own
    /// name here keeps them distinct.
    func displayName(fallback: String) -> String {
        user?.shortName ?? fallback
    }
}

/// A participant's own name, nested under each `SplitwiseExpenseUser` entry
/// by Splitwise's `get_expenses` response — distinct from the account-wide
/// `SplitwiseUser`/`SplitwiseFriend` models in SplitwiseModels.swift, which
/// aren't populated per-expense.
nonisolated struct SplitwiseExpenseParticipant: Codable {
    let firstName: String
    let lastName: String?

    /// First name plus the last name's initial (e.g. "Kim K.") — mirrors
    /// SplitwiseFriend.shortName so a group expense's participants get a
    /// real, distinguishing name instead of collapsing onto `friendName`.
    var shortName: String {
        guard let initial = lastName?.trimmingCharacters(in: .whitespaces).first else { return firstName }
        return "\(firstName) \(initial)."
    }
}

nonisolated struct SplitwiseExpense: Codable, Identifiable {
    let id: Int
    let description: String
    let cost: String
    let currencyCode: String
    let date: Date
    let deletedAt: Date?
    let users: [SplitwiseExpenseUser]
}

nonisolated struct SplitwiseExpensesResponse: Codable {
    let expenses: [SplitwiseExpense]
}

nonisolated extension SplitwiseExpense {
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
    /// covered the cost, otherwise "<name> paid 25 €" for whoever else did.
    /// `friendName` is only a fallback label for that payer — most expenses
    /// are 1:1 with the friend this list was fetched for, but a shared group
    /// expense can have a payer who isn't them, so their own name (from
    /// `SplitwiseExpenseUser.displayName`) is preferred when Splitwise
    /// provides one. Nil if the signed-in user's id isn't cached yet.
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
        return "\(payer.displayName(fallback: friendName)) paid \(payerPaidShare.formatted(.currency(code: currencyCode)))"
    }

    /// One participant's portion of the expense, for the detail view's split
    /// breakdown — labeled "You" for the signed-in user and their own name
    /// (falling back to `friendName`) for everyone else. Reused for both the
    /// owed-share rows and the paid rows.
    struct Share: Identifiable {
        let id: Int
        let name: String
        let amount: Double
    }

    /// How the cost is split, one entry per participant, e.g. "You: 12.50 €",
    /// "Kim: 12.50 €". A shared group expense has more than one non-"You"
    /// participant, so each is labeled with their own name — `friendName` is
    /// only a fallback for the rare case Splitwise didn't provide one (e.g.
    /// a cache written before that field existed).
    func shareBreakdown(friendName: String) -> [Share] {
        let currentUserId = SplitwiseCurrentUserStore.load()?.id
        return users.compactMap { user in
            guard let owed = user.owedShare else { return nil }
            let name = user.userId == currentUserId ? "You" : user.displayName(fallback: friendName)
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
            let name = user.userId == currentUserId ? "You" : user.displayName(fallback: friendName)
            return Share(id: user.userId, name: name, amount: paid)
        }
    }

    /// Who fronted the cost, labeled for the detail view's "Paid by" row —
    /// "You" if the signed-in user paid, otherwise that payer's own name
    /// (falling back to `friendName`). Nil if the signed-in user's id isn't
    /// cached yet or no one shows a paid share.
    func payerName(friendName: String) -> String? {
        guard let currentUserId = SplitwiseCurrentUserStore.load()?.id else { return nil }
        guard let payer = users.first(where: { ($0.paid ?? 0) > 0 }) else { return nil }
        return payer.userId == currentUserId ? "You" : payer.displayName(fallback: friendName)
    }
}
