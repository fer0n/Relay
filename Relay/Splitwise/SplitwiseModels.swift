//
//  SplitwiseModels.swift
//  Relay
//
//  Codable models for the subset of the Splitwise API
//  (https://dev.splitwise.com) used to create an expense split with one
//  friend. JSONDecoder uses snake_case conversion, so property names here
//  are plain camelCase.
//

import Foundation

nonisolated struct SplitwiseUser: Codable {
    let id: Int
    let firstName: String
}

/// Sizes Splitwise returns for a user's avatar — each optionally nil, and the
/// whole `picture` field itself is optional on `SplitwiseFriend`, so a friend
/// with no photo (or a build predating this field) still decodes fine. Note
/// the Optional alone is what buys that tolerance: it must NOT be written as
/// `let picture: SplitwisePicture? = nil`, since the synthesized decoder skips
/// immutable properties that already have a value and would never read the key.
nonisolated struct SplitwisePicture: Codable {
    let small: String?
    let medium: String?
    let large: String?
}

nonisolated struct SplitwiseFriend: Codable {
    let id: Int
    let firstName: String
    let lastName: String?
    let balance: [SplitwiseBalance]?
    let picture: SplitwisePicture?

    /// Disambiguates friends sharing a first name (e.g. in the default
    /// friend picker in ContentView.swift).
    var fullName: String {
        [firstName, lastName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// First name plus the last name's initial (e.g. "Alex K.") — used where
    /// the full surname would be noise, like the per-expense "paid"
    /// subheader in SplitwiseFriendTransactionsView. Falls back to just the
    /// first name when there's no last name.
    var shortName: String {
        guard let initial = lastName?.trimmingCharacters(in: .whitespaces).first else { return firstName }
        return "\(firstName) \(initial)."
    }

    /// True once this friend has a nonzero balance in any shared currency —
    /// used to surface not-yet-settled-up friends first in the pickers.
    /// Splitwise lists a zero-amount entry (rather than omitting it) once a
    /// currency is settled, so this checks the amount, not just presence.
    var hasOutstandingBalance: Bool {
        (balance ?? []).contains { Double($0.amount) != 0 }
    }

    /// The first shared-currency balance, parsed — Splitwise only ever
    /// returns one balance per shared currency, and personal use is expected
    /// to have exactly one, so it's shown plainly rather than summed across
    /// currencies. Positive means the friend owes the signed-in user;
    /// negative means the reverse. Shared by ContentView's balance card and
    /// SplitwiseFriendTransactionsView's navigation subtitle.
    var primaryBalance: (amount: Double, currencyCode: String)? {
        guard let balance = balance?.first, let amount = Double(balance.amount) else { return nil }
        return (amount, balance.currencyCode)
    }

    /// Prefers `medium` (matches the balance card's small avatar circle);
    /// falls back to whichever other size Splitwise did include. Nil for a
    /// friend with no `picture` at all, which the avatar view falls back on
    /// with the plain `Const.Symbol.person` placeholder.
    var avatarURL: URL? {
        guard let urlString = picture?.medium ?? picture?.small ?? picture?.large else { return nil }
        return URL(string: urlString)
    }
}

nonisolated struct SplitwiseBalance: Codable {
    let currencyCode: String
    let amount: String
}

extension Array where Element == SplitwiseFriend {
    /// Splits into (not settled up, settled up), each preserving relative
    /// order — used to group friend pickers under an "Outstanding Balance"
    /// section.
    var partitionedByBalance: (outstanding: [SplitwiseFriend], settled: [SplitwiseFriend]) {
        (filter(\.hasOutstandingBalance), filter { !$0.hasOutstandingBalance })
    }
}

/// Non-group expense split between the signed-in user (who pays the full
/// cost) and one friend, each owing their own share back. Currency mirrors
/// the original Shortcut, which hardcoded EUR. Codable so PendingOperationQueue
/// can persist one to disk while offline.
nonisolated struct SplitwiseExpenseRequest: Codable {
    let costCents: Int
    let description: String
    let currencyCode: String
    let payerUserId: Int
    let payerOwedCents: Int
    let friendUserId: Int
    let friendOwedCents: Int
    /// ISO-8601 date string. Omitted (nil) means "now", which is every call
    /// site's intent except the statement-file-import flow, where the
    /// expense should carry the transaction's actual date instead of today.
    let date: String?

    var asJSONObject: [String: Any] {
        var object: [String: Any] = [
            "cost": splitwiseDecimalString(costCents),
            "description": description,
            "currency_code": currencyCode,
            "group_id": 0,
            "users__0__user_id": payerUserId,
            "users__0__paid_share": splitwiseDecimalString(costCents),
            "users__0__owed_share": splitwiseDecimalString(payerOwedCents),
            "users__1__user_id": friendUserId,
            "users__1__paid_share": "0.00",
            "users__1__owed_share": splitwiseDecimalString(friendOwedCents),
        ]
        if let date {
            object["date"] = date
        }
        return object
    }
}

/// Edit of an expense that already exists on Splitwise — the payload for
/// `update_expense/{id}`, sent from the expense detail screen after the total
/// or someone's share was changed. Distinct from `SplitwiseExpenseRequest`
/// above in more than the endpoint: that one only ever describes the shape
/// Relay itself creates (the signed-in user fronts the whole cost, split with
/// exactly one friend), whereas an expense being edited can have any number
/// of participants and payers, and Splitwise overwrites *every* share as soon
/// as one is supplied — so all of them travel together here.
nonisolated struct SplitwiseExpenseUpdateRequest {
    /// One participant's new shares. `paidCents` is what they fronted,
    /// `owedCents` the portion they're responsible for; Splitwise requires
    /// each of those to add up to `costCents` across all participants.
    struct UserShare {
        let userId: Int
        let paidCents: Int
        let owedCents: Int
    }

    let costCents: Int
    let description: String
    let currencyCode: String
    /// Passed back exactly as Splitwise reported it (0 for a personal
    /// expense) — `update_expense` treats a missing/zero `group_id` as "not
    /// in a group", which would move a group expense out of its group.
    let groupId: Int
    let users: [UserShare]

    var asJSONObject: [String: Any] {
        // `date` is deliberately absent: update_expense leaves out-of-payload
        // fields alone, and this screen doesn't edit the date.
        var object: [String: Any] = [
            "cost": splitwiseDecimalString(costCents),
            "description": description,
            "currency_code": currencyCode,
            "group_id": groupId,
        ]
        for (index, user) in users.enumerated() {
            object["users__\(index)__user_id"] = user.userId
            object["users__\(index)__paid_share"] = splitwiseDecimalString(user.paidCents)
            object["users__\(index)__owed_share"] = splitwiseDecimalString(user.owedCents)
        }
        return object
    }
}

/// Splitwise takes amounts as decimal strings with at most two places.
/// `String(format:)` rather than a locale-aware formatter on purpose: the API
/// wants a `.` decimal separator whatever the device's locale does.
nonisolated private func splitwiseDecimalString(_ cents: Int) -> String {
    String(format: "%.2f", Double(cents) / Const.centsPerUnit)
}

// MARK: - Response envelopes

nonisolated struct SplitwiseCurrentUserResponse: Codable {
    let user: SplitwiseUser
}

nonisolated struct SplitwiseFriendsResponse: Codable {
    let friends: [SplitwiseFriend]
}

nonisolated struct SplitwiseCreateExpenseResponse: Codable {
    let errors: [String: [String]]?
}

/// `update_expense`'s body: the saved expense (Splitwise returns it as a
/// one-element list) plus the same 200-with-`errors` failure channel
/// `create_expense` uses. Both are Optional so a response that only carries
/// one of them still decodes — see `SplitwiseService.updateExpense` for how a
/// missing `expenses` is handled.
nonisolated struct SplitwiseUpdateExpenseResponse: Codable {
    let expenses: [SplitwiseExpense]?
    let errors: [String: [String]]?
}

/// `undelete_expense`'s body. Only `success` is modeled: Splitwise's
/// accompanying `errors` field isn't documented with a stable shape for this
/// endpoint (an object on failure, plausibly an empty array on success), and
/// guessing wrong would fail the decode of an otherwise fine response — see
/// `SplitwiseService.undeleteExpense` for how a failed decode is treated.
nonisolated struct SplitwiseUndeleteExpenseResponse: Codable {
    let success: Bool?
}
