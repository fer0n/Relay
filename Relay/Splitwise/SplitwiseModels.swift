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

/// Avatar sizes, each optional so a friend with no photo still decodes. The
/// Optional alone is what buys that: `let picture: SplitwisePicture? = nil`
/// would NOT work, since the synthesized decoder skips immutable properties that
/// already have a value and would never read the key.
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

    /// Disambiguates friends sharing a first name.
    var fullName: String {
        [firstName, lastName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// First name plus the last name's initial ("Alex K."), for where the full
    /// surname would be noise.
    var shortName: String {
        guard let initial = lastName?.trimmingCharacters(in: .whitespaces).first else { return firstName }
        return "\(firstName) \(initial)."
    }

    /// Surfaces not-yet-settled-up friends first in the pickers. Splitwise keeps
    /// a zero-amount entry once a currency is settled rather than omitting it, so
    /// this checks the amount, not just presence.
    var hasOutstandingBalance: Bool {
        (balance ?? []).contains { Double($0.amount) != 0 }
    }

    /// The first shared-currency balance, positive when the friend owes the
    /// signed-in user. Shown plainly rather than summed, since personal use is
    /// expected to have exactly one currency.
    var primaryBalance: (amount: Double, currencyCode: String)? {
        guard let balance = balance?.first, let amount = Double(balance.amount) else { return nil }
        return (amount, balance.currencyCode)
    }

    /// Prefers `medium`, matching the balance card's avatar circle, and falls back
    /// to whichever other size Splitwise included.
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
    /// Splits into (not settled up, settled up), preserving relative order, so
    /// friend pickers can group under an "Outstanding Balance" section.
    var partitionedByBalance: (outstanding: [SplitwiseFriend], settled: [SplitwiseFriend]) {
        (filter(\.hasOutstandingBalance), filter { !$0.hasOutstandingBalance })
    }
}

/// An expense the signed-in user fronts the full cost of, split across any
/// number of other people — either as a personal expense (`groupId` 0) or
/// posted into a Splitwise group. Codable so PendingOperationQueue can persist
/// one while offline.
nonisolated struct SplitwiseExpenseRequest: Codable {
    /// One person's stake. `paidCents` is only non-zero for the payer, but is
    /// stored per participant because Splitwise validates paid and owed shares
    /// separately, each against the cost.
    nonisolated struct Participant: Codable, Equatable {
        let userId: Int
        let paidCents: Int
        let owedCents: Int
    }

    let costCents: Int
    let description: String
    let currencyCode: String
    /// 0 for a personal expense; a real group id posts the expense into that
    /// group, where Splitwise shows it alongside the group's other expenses.
    let groupId: Int
    /// The payer first, then everyone they're splitting with. Their `owedCents`
    /// must add up to `costCents` exactly, which is what Splitwise validates.
    let participants: [Participant]
    /// ISO-8601. nil means "now" — only the statement-file import sets it, to
    /// carry the transaction's own date instead of today's.
    let date: String?

    init(
        costCents: Int,
        description: String,
        currencyCode: String,
        groupId: Int = 0,
        participants: [Participant],
        date: String? = nil
    ) {
        self.costCents = costCents
        self.description = description
        self.currencyCode = currencyCode
        self.groupId = groupId
        self.participants = participants
        self.date = date
    }

    /// The one-friend shape this type used to be limited to, kept as a
    /// convenience for the single-friend callers (the Shortcuts intents, the
    /// statement-file import) that have no reason to build a participant list.
    init(
        costCents: Int,
        description: String,
        currencyCode: String,
        payerUserId: Int,
        payerOwedCents: Int,
        friendUserId: Int,
        friendOwedCents: Int,
        date: String?
    ) {
        self.init(
            costCents: costCents,
            description: description,
            currencyCode: currencyCode,
            participants: [
                Participant(userId: payerUserId, paidCents: costCents, owedCents: payerOwedCents),
                Participant(userId: friendUserId, paidCents: 0, owedCents: friendOwedCents),
            ],
            date: date
        )
    }

    /// Whoever fronted the money — the first participant by construction, but
    /// resolved by `paidCents` so a payload decoded from anywhere still reads
    /// correctly.
    var payer: Participant? {
        participants.first { $0.paidCents > 0 } ?? participants.first
    }

    var payerUserId: Int { payer?.userId ?? 0 }
    var payerOwedCents: Int { payer?.owedCents ?? 0 }

    /// Everyone the payer split with.
    var others: [Participant] {
        let payerId = payer?.userId
        return participants.filter { $0.userId != payerId }
    }

    var asJSONObject: [String: Any] {
        var object: [String: Any] = [
            "cost": splitwiseDecimalString(costCents),
            "description": description,
            "currency_code": currencyCode,
            "group_id": groupId,
        ]
        for (index, participant) in participants.enumerated() {
            object["users__\(index)__user_id"] = participant.userId
            object["users__\(index)__paid_share"] = splitwiseDecimalString(participant.paidCents)
            object["users__\(index)__owed_share"] = splitwiseDecimalString(participant.owedCents)
        }
        if let date {
            object["date"] = date
        }
        return object
    }

    enum CodingKeys: String, CodingKey {
        case costCents, description, currencyCode, groupId, participants, date
        case payerUserId, payerOwedCents, friendUserId, friendOwedCents
    }

    /// Tolerant of the pre-multi-participant shape, which stored the payer and
    /// the single friend as four flat fields and had no `groupId`. Those
    /// payloads are still on disk in the offline queue and in transaction
    /// history, and the synthesized decoder would throw `keyNotFound` on every
    /// one of them — failing the whole file, not just the entry.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        costCents = try container.decode(Int.self, forKey: .costCents)
        description = try container.decode(String.self, forKey: .description)
        currencyCode = try container.decode(String.self, forKey: .currencyCode)
        groupId = try container.decodeIfPresent(Int.self, forKey: .groupId) ?? 0
        date = try container.decodeIfPresent(String.self, forKey: .date)

        if let participants = try container.decodeIfPresent([Participant].self, forKey: .participants) {
            self.participants = participants
            return
        }
        let payerUserId = try container.decode(Int.self, forKey: .payerUserId)
        let payerOwedCents = try container.decode(Int.self, forKey: .payerOwedCents)
        let friendUserId = try container.decode(Int.self, forKey: .friendUserId)
        let friendOwedCents = try container.decode(Int.self, forKey: .friendOwedCents)
        participants = [
            Participant(userId: payerUserId, paidCents: costCents, owedCents: payerOwedCents),
            Participant(userId: friendUserId, paidCents: 0, owedCents: friendOwedCents),
        ]
    }

    /// Writes only the current shape — the legacy keys are read, never written,
    /// so nothing keeps producing payloads a future decoder has to special-case.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(costCents, forKey: .costCents)
        try container.encode(description, forKey: .description)
        try container.encode(currencyCode, forKey: .currencyCode)
        try container.encode(groupId, forKey: .groupId)
        try container.encode(participants, forKey: .participants)
        try container.encodeIfPresent(date, forKey: .date)
    }
}

/// The payload for `update_expense/{id}`. Distinct from `SplitwiseExpenseRequest`
/// in more than the endpoint: that one only describes the shape Relay creates,
/// whereas an edited expense can have any number of participants and payers — and
/// Splitwise overwrites *every* share as soon as one is supplied, so they all
/// travel together here.
nonisolated struct SplitwiseExpenseUpdateRequest {
    /// Splitwise requires both `paidCents` and `owedCents` to add up to
    /// `costCents` across all participants.
    struct UserShare {
        let userId: Int
        let paidCents: Int
        let owedCents: Int
    }

    let costCents: Int
    let description: String
    let currencyCode: String
    /// Passed back exactly as Splitwise reported it: `update_expense` reads a
    /// missing `group_id` as "not in a group", moving a group expense out of it.
    let groupId: Int
    let users: [UserShare]

    var asJSONObject: [String: Any] {
        // `date` is deliberately absent — update_expense leaves out-of-payload
        // fields alone, and this screen doesn't edit it.
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

/// `String(format:)` rather than a locale-aware formatter: the API wants a `.`
/// decimal separator whatever the device's locale does.
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

nonisolated struct SplitwiseErrorResponse: Codable {
    let errors: [String: [String]]?
}

/// The saved expense (returned as a one-element list) plus the same
/// 200-with-`errors` failure channel `create_expense` uses. Both Optional so a
/// response carrying only one of them still decodes.
nonisolated struct SplitwiseUpdateExpenseResponse: Codable {
    let expenses: [SplitwiseExpense]?
    let errors: [String: [String]]?
}

/// Only `success` is modeled: this endpoint's `errors` field has no documented
/// stable shape (an object on failure, plausibly an empty array on success), and
/// guessing wrong would fail the decode of an otherwise fine response.
nonisolated struct SplitwiseUndeleteExpenseResponse: Codable {
    let success: Bool?
}
