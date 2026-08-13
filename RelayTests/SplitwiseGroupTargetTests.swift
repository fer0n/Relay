//
//  SplitwiseGroupTargetTests.swift
//  RelayTests
//
//  Groups as split targets, and the balances the cards read off them.
//
//  Two things here are invisible to the type system and easy to get backwards.
//  A "Split With" pick is a friend *or* a group sharing one entity type, told
//  apart by `kind` — Splitwise numbers the two separately, so the entity id has
//  to carry the kind as well, and a group has to resolve to its membership minus
//  the signed-in user (the payer). And a group's breakdown flips sign depending
//  on which side of a debt that user is on, with "simplify group debts" changing
//  which figures count at all.
//

import Foundation
import Testing
@testable import Relay

struct SplitwiseGroupTargetTests {
    private static func member(_ id: Int, _ firstName: String) -> SplitwiseGroupMember {
        SplitwiseGroupMember(id: id, firstName: firstName, lastName: "Kim", picture: nil, balance: nil)
    }

    private static let group = SplitwiseGroup(
        id: 7,
        name: "Flat",
        members: [member(1, "You"), member(2, "Alex"), member(3, "Sam")],
        avatar: nil
    )

    /// The caches are real files in the test host's container, so each test puts
    /// back whatever was there.
    private static func withCachedGroup<T>(currentUserId: Int?, _ body: () async throws -> T) async rethrows -> T {
        let previousGroups = SplitwiseGroupCacheStore.load()
        let previousUser = SplitwiseCurrentUserStore.load()
        defer {
            if let previousGroups {
                SplitwiseGroupCacheStore.save(previousGroups)
            } else {
                SplitwiseGroupCacheStore.delete()
            }
            if let previousUser {
                try? SplitwiseCurrentUserStore.save(previousUser)
            } else {
                SplitwiseCurrentUserStore.delete()
            }
        }
        SplitwiseGroupCacheStore.save([group])
        if let currentUserId {
            try? SplitwiseCurrentUserStore.save(SplitwiseUser(id: currentUserId, firstName: "You"))
        } else {
            SplitwiseCurrentUserStore.delete()
        }
        return try await body()
    }

    @Test
    func aGroupAndAFriendSharingANumberAreDifferentEntities() {
        let group = SplitwiseSplitTargetEntity(group: Self.group)
        let friend = SplitwiseSplitTargetEntity(splitwiseId: 7, firstName: "Alex", fullName: "Alex Kim")

        #expect(group.kind == .group)
        #expect(friend.kind == .friend)
        #expect(group.splitwiseId == friend.splitwiseId)
        // Shortcuts stores the entity id to remember the pick, so the two must
        // not collide on it.
        #expect(group.id == "group-7")
        #expect(friend.id == "friend-7")
        // The group's name stands in for both name fields.
        #expect(group.firstName == "Flat")
    }

    @Test
    func aCachedTargetRoundTripsThroughTheEntity() {
        let cached = SplitwiseSplitTargetEntity(group: Self.group).cachedTarget
        #expect(cached.isGroup)
        #expect(cached.id == 7)
        #expect(SplitwiseSplitTargetEntity(cachedTarget: cached).kind == .group)

        let friendCached = SplitwiseSplitTargetEntity(splitwiseId: 7, firstName: "Alex", fullName: "Alex Kim").cachedTarget
        #expect(!friendCached.isGroup)
        #expect(SplitwiseSplitTargetEntity(cachedTarget: friendCached).kind == .friend)
    }

    @Test
    func aGroupResolvesToItsMembersWithoutTheSignedInUser() async throws {
        try await Self.withCachedGroup(currentUserId: 1) {
            let target = try await SplitwiseExpenseHelper.splitTarget(for: SplitwiseSplitTargetEntity(group: Self.group))

            #expect(target.groupId == 7)
            #expect(target.groupName == "Flat")
            // Member 1 is the payer, and would otherwise be billed twice.
            #expect(target.participants.map(\.id) == [2, 3])
            // Named after the group, not listed one by one.
            #expect(target.displayName == "Flat")
            // A group is never the "one cached friend" a template stores.
            #expect(target.soleFriend == nil)
        }
    }

    /// The Balances grid reads a group's standing off the signed-in user's own
    /// member entry — theirs, not the other members', which describe what *they*
    /// are up or down inside the group.
    @Test
    func aGroupsBalanceIsTheSignedInUsersOwnMemberEntry() {
        let group = SplitwiseGroup(
            id: 7,
            name: "Flat",
            members: [
                SplitwiseGroupMember(id: 1, firstName: "You", lastName: nil, picture: nil, balance: [SplitwiseBalance(currencyCode: "EUR", amount: "-31.75")]),
                SplitwiseGroupMember(id: 2, firstName: "Alex", lastName: nil, picture: nil, balance: [SplitwiseBalance(currencyCode: "EUR", amount: "31.75")]),
            ],
            avatar: nil
        )

        #expect(group.currentUserBalance(currentUserId: 1)?.amount == -31.75)
        #expect(group.currentUserBalance(currentUserId: 1)?.currencyCode == "EUR")
        #expect(group.hasOutstandingBalance(currentUserId: 1))
        // Without the signed-in id there's no entry to read, so it can't claim
        // to be outstanding.
        #expect(group.currentUserBalance(currentUserId: nil) == nil)
        #expect(!group.hasOutstandingBalance(currentUserId: nil))
    }

    @Test
    func aSettledGroupIsNotOutstandingDespiteCarryingAZeroEntry() {
        // Splitwise keeps a zero-amount balance once a currency is settled
        // rather than dropping it.
        let group = SplitwiseGroup(
            id: 8,
            name: "Trip",
            members: [SplitwiseGroupMember(id: 1, firstName: "You", lastName: nil, picture: nil, balance: [SplitwiseBalance(currencyCode: "EUR", amount: "0.0")])],
            avatar: nil
        )

        #expect(!group.hasOutstandingBalance(currentUserId: 1))
    }

    /// With "simplify group debts" off, each member's own group balance is the
    /// breakdown the card shows.
    @Test
    func withoutSimplificationEachMembersOwnBalanceStands() {
        let group = SplitwiseGroup(
            id: 7,
            name: "Flat",
            members: [
                SplitwiseGroupMember(id: 1, firstName: "You", lastName: nil, picture: nil, balance: [SplitwiseBalance(currencyCode: "EUR", amount: "-25.0")]),
                SplitwiseGroupMember(id: 2, firstName: "Katha", lastName: "Berg", picture: nil, balance: [SplitwiseBalance(currencyCode: "EUR", amount: "25.0")]),
                SplitwiseGroupMember(id: 3, firstName: "Sam", lastName: nil, picture: nil, balance: [SplitwiseBalance(currencyCode: "EUR", amount: "0.0")]),
            ],
            avatar: nil
        )

        let standings = group.memberStandings(currentUserId: 1)
        // The signed-in user isn't in their own breakdown, and a settled member
        // is left out rather than listed as zero.
        #expect(standings.map(\.memberId) == [2])
        #expect(standings.first?.name == "Katha B.")
        #expect(standings.first?.amount == 25)
    }

    /// With it on, a member's raw balance can disagree with what the signed-in
    /// user actually owes them — Splitwise's own simplified_debts is the answer.
    @Test
    func simplificationReportsWhatTheUserActuallyOwes() {
        let group = SplitwiseGroup(
            id: 7,
            name: "Flat",
            members: [
                SplitwiseGroupMember(id: 1, firstName: "You", lastName: nil, picture: nil, balance: [SplitwiseBalance(currencyCode: "EUR", amount: "-25.0")]),
                SplitwiseGroupMember(id: 2, firstName: "Katha", lastName: nil, picture: nil, balance: [SplitwiseBalance(currencyCode: "EUR", amount: "25.0")]),
                SplitwiseGroupMember(id: 3, firstName: "Sam", lastName: nil, picture: nil, balance: [SplitwiseBalance(currencyCode: "EUR", amount: "0.0")]),
            ],
            avatar: nil,
            simplifyByDefault: true,
            simplifiedDebts: [
                // The chain "you owe Katha, Katha owes Sam" collapsed: you pay Sam.
                SplitwiseSimplifiedDebt(from: 1, to: 3, amount: "25.0", currencyCode: "EUR"),
                // Someone else's leg, none of the user's business.
                SplitwiseSimplifiedDebt(from: 2, to: 3, amount: "10.0", currencyCode: "EUR"),
            ]
        )

        let standings = group.memberStandings(currentUserId: 1)
        // Sam, not Katha, despite Katha's raw balance saying she's owed 25.
        #expect(standings.map(\.memberId) == [3])
        // Positive: Sam is owed, by the signed-in user.
        #expect(standings.first?.amount == 25)
        #expect(standings.first?.name == "Sam")
    }

    @Test
    func simplificationFlipsTheSignWhenTheUserIsOwed() {
        let group = SplitwiseGroup(
            id: 7,
            name: "Flat",
            members: [
                SplitwiseGroupMember(id: 1, firstName: "You", lastName: nil, picture: nil, balance: nil),
                SplitwiseGroupMember(id: 2, firstName: "Katha", lastName: nil, picture: nil, balance: nil),
            ],
            avatar: nil,
            simplifyByDefault: true,
            simplifiedDebts: [SplitwiseSimplifiedDebt(from: 2, to: 1, amount: "18.0", currencyCode: "EUR")]
        )

        let standings = group.memberStandings(currentUserId: 1)
        // Katha owes the user, so from her side she is down.
        #expect(standings.first?.amount == -18)
    }

    /// Splitwise sends `simplified_debts` whether or not the setting is on, so
    /// the flag is what decides — otherwise a group with it off would show
    /// simplified figures its own app doesn't.
    @Test
    func simplifiedDebtsAreIgnoredWhileTheSettingIsOff() {
        let group = SplitwiseGroup(
            id: 7,
            name: "Flat",
            members: [
                SplitwiseGroupMember(id: 1, firstName: "You", lastName: nil, picture: nil, balance: [SplitwiseBalance(currencyCode: "EUR", amount: "-25.0")]),
                SplitwiseGroupMember(id: 2, firstName: "Katha", lastName: nil, picture: nil, balance: [SplitwiseBalance(currencyCode: "EUR", amount: "25.0")]),
                SplitwiseGroupMember(id: 3, firstName: "Sam", lastName: nil, picture: nil, balance: nil),
            ],
            avatar: nil,
            simplifyByDefault: false,
            simplifiedDebts: [SplitwiseSimplifiedDebt(from: 1, to: 3, amount: "25.0", currencyCode: "EUR")]
        )

        #expect(group.memberStandings(currentUserId: 1).map(\.memberId) == [2])
    }

    @Test
    func aFriendEntityResolvesToItselfAsAPersonalExpense() async throws {
        let target = try await SplitwiseExpenseHelper.splitTarget(
            for: SplitwiseSplitTargetEntity(splitwiseId: 42, firstName: "Alex", fullName: "Alex Kim")
        )

        #expect(target.groupId == nil)
        #expect(target.participants.map(\.id) == [42])
        #expect(target.soleFriend?.id == 42)
    }
}
