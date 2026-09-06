//
//  LedgerParticipantTests.swift
//  RelayTests
//
//  Who counts as billable on a ledger. Getting this wrong doesn't throw — it
//  quietly bills the wrong set of people, so these pin down the two cases that
//  caused real trouble: a pending invitee being charged for something they
//  can't see, and a participant lingering after the owner removed them.
//

import CloudKit
import Foundation
import Testing
@testable import Relay

struct LedgerParticipantTests {
    private static func ledger(_ participants: [LedgerParticipant]) -> Ledger {
        Ledger(
            zoneID: .init(zoneName: "Ledger-1", ownerName: "_owner"),
            name: "Flat",
            currencyCode: "EUR",
            createdAt: Date(),
            isOwnedByCurrentUser: true,
            participants: participants
        )
    }

    private static let me = LedgerParticipant(id: "me", name: nil, isCurrentUser: true, hasAccepted: true, isOwner: true)
    private static let accepted = LedgerParticipant(id: "alex", name: "Alex Kim", isCurrentUser: false, hasAccepted: true, isOwner: false)
    private static let pending = LedgerParticipant(id: "sam", name: nil, isCurrentUser: false, hasAccepted: false, isOwner: false)

    /// The bug this was written for: an invite that's never accepted was being
    /// billed, creating a balance the other person can't even see, let alone
    /// settle.
    @Test
    func aPendingInviteIsNotBillable() {
        let ledger = Self.ledger([Self.me, Self.accepted, Self.pending])
        #expect(ledger.others.map(\.id) == ["alex"])
        #expect(ledger.pendingInvites.map(\.id) == ["sam"])
    }

    @Test
    func aPendingInviteIsLeftOffASplitTarget() {
        let target = SplitTarget(ledger: Self.ledger([Self.me, Self.accepted, Self.pending]))
        #expect(target.participants.map(\.id) == ["alex"])
    }

    /// A ledger whose only other person hasn't accepted can't be split on yet,
    /// so it mustn't be offered as a destination.
    @Test
    func aLedgerWithOnlyAPendingInviteIsNotShared() {
        #expect(!Self.ledger([Self.me, Self.pending]).isShared)
        #expect(Self.ledger([Self.me, Self.accepted]).isShared)
    }

    @Test
    func aPendingInviteIsLeftOutOfTheParticipantsSummary() {
        let ledger = Self.ledger([Self.me, Self.accepted, Self.pending])
        #expect(ledger.participantsSummary == "Alex")
    }

    /// Historical shares still resolve by id, so an expense already billed to
    /// someone keeps naming them even once they're only a pending invite (or
    /// gone) — the balance math never loses track of what was already owed.
    @Test
    func aParticipantStillResolvesByIdRegardlessOfAcceptance() {
        let ledger = Self.ledger([Self.me, Self.accepted, Self.pending])
        #expect(ledger.participant(id: "sam") != nil)
    }

    /// CloudKit reveals a name only to viewers the person is discoverable to,
    /// so an accepted participant can legitimately have none. Calling them
    /// "Invited" would say they aren't on the ledger when they are.
    @Test
    func anAcceptedParticipantWithNoResolvableNameIsNotCalledInvited() {
        let unnamed = LedgerParticipant(id: "x", name: nil, isCurrentUser: false, hasAccepted: true, isOwner: false)
        #expect(unnamed.displayName == "Someone")
        #expect(unnamed.displayName != LedgerParticipant.invitedName)
    }

    @Test
    func aPendingParticipantWithNoResolvableNameIsCalledInvited() {
        #expect(Self.pending.displayName == LedgerParticipant.invitedName)
    }

    @Test
    func theCurrentUserIsAlwaysCalledYou() {
        #expect(Self.me.displayName == "You")
        let unnamedMe = LedgerParticipant(id: "me", name: nil, isCurrentUser: true, hasAccepted: true, isOwner: true)
        #expect(unnamedMe.displayName == "You")
    }

    @Test
    func balancesAreUnaffectedByWhoIsCurrentlyBillable() {
        // Someone who has since become unbillable still owes what they owed.
        let expense = LedgerExpense(
            title: "Dinner",
            costCents: 2000,
            currencyCode: "EUR",
            date: Date(),
            shares: [
                LedgerExpenseShare(participantID: "me", paidCents: 2000, owedCents: 1000),
                LedgerExpenseShare(participantID: "sam", paidCents: 0, owedCents: 1000),
            ]
        )
        #expect(LedgerBalanceMath.netCents(for: "me", expenses: [expense]) == 1000)
        #expect(LedgerBalanceMath.netCents(for: "sam", expenses: [expense]) == -1000)
    }
}
