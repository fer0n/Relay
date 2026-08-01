//
//  SplitwiseExpense.swift
//  Relay
//
//  Codable models for `get_expenses` (https://dev.splitwise.com) — the expense
//  history shared with a friend, as opposed to SplitwiseModels.swift's
//  SplitwiseExpenseRequest, the one-way "create an expense" payload.
//

import Foundation

nonisolated struct SplitwiseExpenseUser: Codable {
    let userId: Int
    let paidShare: String
    let netBalance: String
    /// Optional so a cache file written before this field existed still decodes;
    /// callers fall back to `friendName` when nil.
    let user: SplitwiseExpenseParticipant?

    var paid: Double? { Double(paidShare) }

    /// Splitwise gives net_balance = paid_share - owed_share, so the owed share
    /// is paid_share - net_balance.
    var owedShare: Double? {
        guard let paid = Double(paidShare), let net = Double(netBalance) else { return nil }
        return paid - net
    }

    /// Expenses aren't always 1:1 with a single friend — a group expense has
    /// several non-"You" participants, and reusing one `friendName` for all of
    /// them would collapse them onto the same label.
    func displayName(fallback: String) -> String {
        user?.shortName ?? fallback
    }

    /// "You" for the signed-in user, `displayName(fallback:)` for everyone else.
    /// The signed-in id is passed in rather than read from the store, so labeling
    /// a whole expense is one lookup instead of one per person.
    func label(currentUserId: Int?, fallback: String) -> String {
        userId == currentUserId ? String(localized: "You") : displayName(fallback: fallback)
    }
}

/// Nested under each `SplitwiseExpenseUser` in `get_expenses` — distinct from the
/// account-wide models in SplitwiseModels.swift, which aren't populated
/// per-expense.
nonisolated struct SplitwiseExpenseParticipant: Codable {
    let firstName: String
    let lastName: String?

    /// Mirrors SplitwiseFriend.shortName.
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
    /// 0/nil for a personal expense. Only read back out to be sent unchanged on
    /// `update_expense`, where passing 0 would pull a group expense out of its
    /// group. Optional so an older cache file still decodes — and the Optional
    /// alone is what buys that, so it must not be given a default value.
    let groupId: Int?
}

nonisolated struct SplitwiseExpensesResponse: Codable {
    let expenses: [SplitwiseExpense]
}

nonisolated extension SplitwiseExpense {
    /// Positive if the signed-in user is owed. Nil when their id isn't cached yet,
    /// in which case callers show the plain unsigned `cost`.
    var currentUserNetBalance: Double? {
        guard let userId = SplitwiseCurrentUserStore.load()?.id,
              let entry = users.first(where: { $0.userId == userId }),
              let value = Double(entry.netBalance) else { return nil }
        return value
    }

    /// The row/detail subheader, e.g. "You paid 25 €". `friendName` is only a
    /// fallback label for the payer: a group expense can have one who isn't the
    /// friend this list was fetched for. Nil until the signed-in id is cached.
    func payerDescription(friendName: String) -> String? {
        guard let userId = SplitwiseCurrentUserStore.load()?.id,
              let entry = users.first(where: { $0.userId == userId }),
              let ownPaidShare = Double(entry.paidShare) else { return nil }

        if ownPaidShare > 0 {
            return "You paid \(ownPaidShare.formatted(.currency(code: currencyCode)))"
        }
        // Falls back to the plain cost when no one else shows a paid share.
        guard let payer = users.first(where: { $0.userId != userId && (Double($0.paidShare) ?? 0) > 0 }),
              let payerPaidShare = Double(payer.paidShare) else {
            return "\(friendName) paid"
        }
        return "\(payer.displayName(fallback: friendName)) paid \(payerPaidShare.formatted(.currency(code: currencyCode)))"
    }
}
