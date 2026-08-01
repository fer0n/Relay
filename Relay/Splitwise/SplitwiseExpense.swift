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

    /// How this participant is labeled in a split breakdown: "You" for the
    /// signed-in user, `displayName(fallback:)` for everyone else. The
    /// signed-in id is passed in rather than read from
    /// SplitwiseCurrentUserStore here, so labeling a whole expense's
    /// participants is one lookup instead of one per person.
    func label(currentUserId: Int?, fallback: String) -> String {
        userId == currentUserId ? String(localized: "You") : displayName(fallback: fallback)
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
    /// The group this expense belongs to, or 0/nil when it's a personal
    /// (non-group) one. Only read back out to be sent unchanged on
    /// `update_expense`, which requires `group_id` — passing 0 there would
    /// silently pull a group expense out of its group. Optional so a cache
    /// file written before this field existed still decodes (see
    /// SplitwiseExpenseCacheStore); the Optional alone is what buys that, so
    /// it must not be given a default value.
    let groupId: Int?
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
}
