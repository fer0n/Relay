//
//  SplitwiseSplitTarget.swift
//  Relay
//
//  Who an expense is split with, and how the cost divides between them.
//
//  `SplitwiseSplitSelection` is what the participant picker binds to — ids
//  only, so it can be held by a form and compared cheaply.
//  `SplitwiseSplitTarget` is that selection resolved against the cached friend
//  and group lists: the actual people, with names, that a write needs.
//  `SplitwiseSplitAllocation` is the arithmetic, kept here (and out of the
//  views) so an even split, a typed own share, and relative weights all end up
//  going through the same whole-cent distribution Splitwise validates.
//

import Foundation

/// One resolved person on an expense, other than the signed-in user.
nonisolated struct SplitwiseSplitParticipant: Equatable, Identifiable {
    let id: Int
    let firstName: String
    let fullName: String

    init(id: Int, firstName: String, fullName: String) {
        self.id = id
        self.firstName = firstName
        self.fullName = fullName
    }

    init(friend: SplitwiseFriend) {
        self.init(id: friend.id, firstName: friend.firstName, fullName: friend.fullName)
    }

    init(member: SplitwiseGroupMember) {
        self.init(id: member.id, firstName: member.firstName, fullName: member.fullName)
    }

    init(entity: SplitwiseSplitTargetEntity) {
        self.init(id: entity.splitwiseId, firstName: entity.firstName, fullName: entity.fullName)
    }
}

/// The picker's state: who's on the split, and — separately — which group it's
/// posted to. Picking a group fills the participants with its membership, but
/// the two stay independent afterwards, so a member can be dropped from this
/// one expense while it still books under the group.
nonisolated struct SplitwiseSplitSelection: Equatable, Codable {
    private(set) var participantIds: [Int] = []
    private(set) var groupId: Int?

    init(participantIds: [Int] = [], groupId: Int? = nil) {
        self.participantIds = participantIds
        self.groupId = groupId
    }

    static let empty = SplitwiseSplitSelection()

    static func friend(_ id: Int) -> SplitwiseSplitSelection {
        SplitwiseSplitSelection(participantIds: [id])
    }

    static func group(_ id: Int, memberIds: [Int]) -> SplitwiseSplitSelection {
        SplitwiseSplitSelection(participantIds: memberIds, groupId: id)
    }

    var isEmpty: Bool { participantIds.isEmpty && groupId == nil }

    func contains(_ id: Int) -> Bool { participantIds.contains(id) }

    mutating func add(_ id: Int) {
        guard !participantIds.contains(id) else { return }
        participantIds.append(id)
    }

    mutating func remove(_ id: Int) {
        participantIds.removeAll { $0 == id }
    }

    /// Replaces the participants with the group's own membership — switching
    /// groups swaps who's on the expense rather than piling them up.
    mutating func setGroup(_ id: Int, memberIds: [Int]) {
        groupId = id
        participantIds = memberIds
    }

    /// Leaves everyone already picked in place: dropping the group turns this
    /// back into a personal expense with the same people on it, which is a less
    /// destructive reading of "not in this group after all" than clearing them.
    mutating func clearGroup() {
        groupId = nil
    }
}

/// A selection resolved to the people it actually bills.
nonisolated struct SplitwiseSplitTarget: Equatable {
    /// Everyone but the signed-in user. Never empty for a usable target.
    let participants: [SplitwiseSplitParticipant]
    /// nil for a personal expense.
    let groupId: Int?
    /// Only for wording ("split with Flat"); nil when this isn't a group.
    let groupName: String?

    init(participants: [SplitwiseSplitParticipant], groupId: Int? = nil, groupName: String? = nil) {
        self.participants = participants
        self.groupId = groupId
        self.groupName = groupName
    }

    init(friend: SplitwiseSplitTargetEntity) {
        self.init(participants: [SplitwiseSplitParticipant(entity: friend)])
    }

    /// What a completion/queue summary calls this split — the group's name when
    /// there is one, otherwise the participants' first names.
    var displayName: String {
        if let groupName { return groupName }
        return ListFormatter.localizedString(byJoining: participants.map(\.firstName))
    }

    /// The single friend this target bills, when that's all it is. Nil for a
    /// group or a multi-person split — used by the surfaces that still store
    /// exactly one friend (a template's cached friend, the default friend).
    var soleFriend: SplitwiseSplitParticipant? {
        guard groupId == nil, participants.count == 1 else { return nil }
        return participants.first
    }
}

nonisolated extension SplitwiseExpenseRequest {
    /// Who owes what, for the history/queue rows: "Alex: 12.00 €", or
    /// "Alex: 8.00 €, Sam: 4.00 €" once several people are on it. A group
    /// expense collapses to the group's name and what it owes as a whole, which
    /// stays readable however many members it has.
    ///
    /// Names come from the local caches, so this is nil until something's
    /// cached — the rows treat that the same as having no split to describe.
    var participantsShareSummary: String? {
        let groups = SplitwiseGroupCacheStore.load() ?? []
        let othersOwed = others.reduce(0) { $0 + $1.owedCents }

        if groupId != 0 {
            guard let group = groups.first(where: { $0.id == groupId }) else { return nil }
            return "\(group.name): \(formattedShare(othersOwed))"
        }

        let friends = SplitwiseFriendCacheStore.load() ?? []
        let members = groups.flatMap(\.memberList)
        let parts = others.compactMap { participant -> String? in
            let name = friends.first { $0.id == participant.userId }?.firstName
                ?? members.first { $0.id == participant.userId }?.firstName
            guard let name else { return nil }
            return "\(name): \(formattedShare(participant.owedCents))"
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private func formattedShare(_ cents: Int) -> String {
        (Double(cents) / Const.centsPerUnit).formatted(.currency(code: currencyCode))
    }
}

/// How `costCents` divides across the payer and everyone they split with.
nonisolated enum SplitwiseSplitAllocation: Equatable {
    /// An even split across the payer and every participant.
    case equal
    /// The payer owes exactly this; the rest spreads evenly across the others.
    case ownShare(cents: Int)
    /// Relative weights — the payer's first, then one per participant in order.
    case weights([Double])

    /// Owed cents as `[payer, participants…]`, adding up to `totalCents`
    /// exactly. Nil when the inputs can't describe a split: nobody to split
    /// with, an own share outside the total, a weight list that doesn't match
    /// the participants or is all zeroes.
    func owedCents(totalCents: Int, participantCount: Int) -> [Int]? {
        guard participantCount > 0, totalCents >= 0 else { return nil }
        switch self {
        case .equal:
            return SplitwiseShareMath.distribute(
                totalCents: totalCents,
                ratios: SplitwiseShareMath.evenRatios(count: participantCount + 1)
            )
        case .ownShare(let cents):
            guard (0...totalCents).contains(cents) else { return nil }
            let rest = SplitwiseShareMath.distribute(
                totalCents: totalCents - cents,
                ratios: SplitwiseShareMath.evenRatios(count: participantCount)
            )
            return [cents] + rest
        case .weights(let weights):
            guard weights.count == participantCount + 1,
                  weights.allSatisfy({ $0 >= 0 }),
                  weights.reduce(0, +) > 0 else { return nil }
            return SplitwiseShareMath.distribute(
                totalCents: totalCents,
                ratios: SplitwiseShareMath.ratios(of: weights)
            )
        }
    }
}
