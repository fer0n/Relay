//
//  SplitwiseGroup.swift
//  Relay
//
//  Codable models for `get_groups` (https://dev.splitwise.com). A group is a
//  pickable split target in its own right: choosing one posts the expense with
//  that group's real `group_id`, split across its members, which is what makes
//  it show up under the group in Splitwise rather than as a pile of one-to-one
//  expenses.
//

import Foundation

/// One person in a group. Deliberately not `SplitwiseFriend`: a member's
/// `balance` is their standing *within this group* rather than with the
/// signed-in user, and a group can contain someone who isn't in that user's
/// friend list at all.
nonisolated struct SplitwiseGroupMember: Codable, Identifiable, Equatable {
    let id: Int
    let firstName: String
    let lastName: String?
    let picture: SplitwisePicture?
    /// This member's balance *within the group*. Optional so a member entry
    /// without one still decodes; the signed-in user's is what the Balances
    /// screen shows for the group.
    let balance: [SplitwiseBalance]?

    /// Mirrors `SplitwiseFriend.fullName`.
    var fullName: String {
        [firstName, lastName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Mirrors `SplitwiseFriend.shortName`.
    var shortName: String {
        guard let initial = lastName?.trimmingCharacters(in: .whitespaces).first else { return firstName }
        return "\(firstName) \(initial)."
    }

    /// Mirrors `SplitwiseFriend.avatarURL`.
    var avatarURL: URL? {
        guard let urlString = picture?.medium ?? picture?.small ?? picture?.large else { return nil }
        return URL(string: urlString)
    }

    static func == (lhs: SplitwiseGroupMember, rhs: SplitwiseGroupMember) -> Bool {
        lhs.id == rhs.id
    }
}

/// One leg of `get_groups`' `simplified_debts`: `from` owes `to`. Splitwise
/// computes these itself, collapsing chains (I owe B, B owes C → I owe C).
nonisolated struct SplitwiseSimplifiedDebt: Codable, Equatable {
    let from: Int
    let to: Int
    let amount: String
    let currencyCode: String
}

nonisolated struct SplitwiseGroup: Codable, Identifiable, Equatable {
    let id: Int
    let name: String
    /// Optional so a group whose member list Splitwise omits still decodes; an
    /// empty membership is filtered out of the picker rather than offered as a
    /// target nobody would be billed under.
    let members: [SplitwiseGroupMember]?
    /// `avatar` rather than `picture`, per `get_groups`. The extra sizes
    /// Splitwise sends alongside (`original`, `xxlarge`, …) are ignored.
    let avatar: SplitwisePicture?
    /// Whether the group has Splitwise's "simplify group debts" turned on.
    /// Optional so a cache file written before this field existed still decodes.
    let simplifyByDefault: Bool?
    /// Who owes whom once Splitwise has collapsed the chains. Only meaningful
    /// when `simplifyByDefault` is true — Splitwise sends the field either way.
    let simplifiedDebts: [SplitwiseSimplifiedDebt]?

    /// Spelled out, with defaults for the two fields only the simplify-debts
    /// path reads, so previews and tests don't have to name them.
    init(
        id: Int,
        name: String,
        members: [SplitwiseGroupMember]?,
        avatar: SplitwisePicture?,
        simplifyByDefault: Bool? = nil,
        simplifiedDebts: [SplitwiseSimplifiedDebt]? = nil
    ) {
        self.id = id
        self.name = name
        self.members = members
        self.avatar = avatar
        self.simplifyByDefault = simplifyByDefault
        self.simplifiedDebts = simplifiedDebts
    }

    var memberList: [SplitwiseGroupMember] { members ?? [] }

    var avatarURL: URL? {
        guard let urlString = avatar?.medium ?? avatar?.small ?? avatar?.large else { return nil }
        return URL(string: urlString)
    }

    /// Everyone but the signed-in user — who they are is passed in rather than
    /// read from the store so labeling a list of groups is one lookup.
    func others(excluding currentUserId: Int?) -> [SplitwiseGroupMember] {
        memberList.filter { $0.id != currentUserId }
    }

    /// What the signed-in user is up or down in this group — positive when the
    /// group owes them, matching `SplitwiseFriend.primaryBalance`. Nil when
    /// their id isn't known yet or the group carries no balance for them.
    func currentUserBalance(currentUserId: Int?) -> (amount: Double, currencyCode: String)? {
        guard let currentUserId,
              let member = memberList.first(where: { $0.id == currentUserId }),
              let balance = member.balance?.first,
              let amount = Double(balance.amount) else { return nil }
        return (amount, balance.currencyCode)
    }

    /// Mirrors `SplitwiseFriend.hasOutstandingBalance`: Splitwise keeps a
    /// zero-amount entry once a currency is settled rather than omitting it, so
    /// this checks the amount.
    func hasOutstandingBalance(currentUserId: Int?) -> Bool {
        guard let member = memberList.first(where: { $0.id == currentUserId }) else { return false }
        return (member.balance ?? []).contains { Double($0.amount) != 0 }
    }

    /// What each *other* person in the group is up or down, positive when
    /// they're owed. This is what the balance card breaks down under the
    /// group's own figure.
    ///
    /// With "simplify group debts" on, Splitwise's own `simplified_debts` is the
    /// honest answer: a member's raw balance can say they're owed 25 while the
    /// simplification means the signed-in user owes them nothing, since someone
    /// else settles it. Only debts involving the signed-in user are reported
    /// then — the rest are other people's business, and the app shows them the
    /// same way.
    ///
    /// Without it, each member's own group balance stands as-is.
    func memberStandings(currentUserId: Int?) -> [MemberStanding] {
        guard simplifyByDefault == true, let currentUserId, let simplifiedDebts else {
            return memberStandings(fromBalancesExcluding: currentUserId)
        }
        return simplifiedDebts.compactMap { debt in
            guard let amount = Double(debt.amount), amount != 0 else { return nil }
            let otherId: Int
            let signedAmount: Double
            switch currentUserId {
            case debt.from:
                // The user owes them, so from their side they're owed.
                otherId = debt.to
                signedAmount = amount
            case debt.to:
                otherId = debt.from
                signedAmount = -amount
            default:
                return nil
            }
            guard let member = memberList.first(where: { $0.id == otherId }) else { return nil }
            return MemberStanding(memberId: otherId, name: member.shortName, amount: signedAmount, currencyCode: debt.currencyCode)
        }
    }

    private func memberStandings(fromBalancesExcluding currentUserId: Int?) -> [MemberStanding] {
        others(excluding: currentUserId).compactMap { member in
            guard let entry = member.balance?.first,
                  let amount = Double(entry.amount),
                  amount != 0 else { return nil }
            return MemberStanding(memberId: member.id, name: member.shortName, amount: amount, currencyCode: entry.currencyCode)
        }
    }

    nonisolated struct MemberStanding: Equatable, Identifiable {
        let memberId: Int
        let name: String
        /// Positive when this person is owed.
        let amount: Double
        let currencyCode: String

        var id: Int { memberId }
    }

    static func == (lhs: SplitwiseGroup, rhs: SplitwiseGroup) -> Bool {
        lhs.id == rhs.id
    }
}

nonisolated struct SplitwiseGroupsResponse: Codable {
    let groups: [SplitwiseGroup]
}
