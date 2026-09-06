//
//  SplitTargetTests.swift
//  RelayTests
//
//  `SplitTarget` decides who an expense actually bills, so the distinctions it
//  draws are the ones that put money on the wrong person's balance if they
//  slip: the signed-in user is never billed, and "everyone on the ledger" is
//  not the same target as "these two people who happen to be all of it today".
//

import Foundation
import Testing
@testable import Relay

struct SplitTargetTests {
    private static func ledger(participants: [LedgerParticipant]) -> Ledger {
        Ledger(
            zoneID: .init(zoneName: "Ledger-1", ownerName: "_owner"),
            name: "Flat",
            currencyCode: "EUR",
            createdAt: Date(),
            isOwnedByCurrentUser: true,
            participants: participants
        )
    }

    private static let me = LedgerParticipant(id: "me", name: "Me", isCurrentUser: true, hasAccepted: true, isOwner: true)
    private static let alex = LedgerParticipant(id: "alex", name: "Alex Kim", isCurrentUser: false, hasAccepted: true, isOwner: false)
    private static let sam = LedgerParticipant(id: "sam", name: "Sam Ray", isCurrentUser: false, hasAccepted: true, isOwner: false)

    @Test
    func aLedgerTargetExcludesTheSignedInUser() {
        let target = SplitTarget(ledger: Self.ledger(participants: [Self.me, Self.alex, Self.sam]))
        #expect(target.participants.map(\.id) == ["alex", "sam"])
        #expect(target.zoneName == "Ledger-1")
    }

    @Test
    func aLedgerNobodyElseIsOnMakesAnEmptyTarget() {
        let target = SplitTarget(ledger: Self.ledger(participants: [Self.me]))
        #expect(target.isEmpty)
    }

    @Test
    func aWholeLedgerIsNamedAfterTheLedger() {
        let target = SplitTarget(ledger: Self.ledger(participants: [Self.me, Self.alex, Self.sam]))
        #expect(target.displayName == "Flat")
    }

    @Test
    func asubsetIsNamedAfterThePeopleOnIt() {
        let target = SplitTarget(
            participants: [SplitParticipant(Self.alex)],
            zoneName: "Ledger-1"
        )
        #expect(target.displayName == "Alex")
    }

    /// The distinction a template relies on: a whole-ledger split has no single
    /// person to remember, so it must not be mistaken for a one-person one —
    /// caching it would pin the template to whoever happened to be on the
    /// ledger that day.
    @Test
    func aWholeLedgerHasNoSoleParticipantEvenWithOnePersonOnIt() {
        let target = SplitTarget(ledger: Self.ledger(participants: [Self.me, Self.alex]))
        #expect(target.participants.count == 1)
        #expect(target.soleParticipant == nil)
    }

    @Test
    func aOnePersonSplitHasASoleParticipant() {
        let target = SplitTarget(
            participants: [SplitParticipant(Self.alex)],
            zoneName: "Ledger-1"
        )
        #expect(target.soleParticipant?.id == "alex")
    }

    @Test
    func aMultiPersonSubsetHasNoSoleParticipant() {
        let target = SplitTarget(
            participants: [SplitParticipant(Self.alex), SplitParticipant(Self.sam)],
            zoneName: "Ledger-1"
        )
        #expect(target.soleParticipant == nil)
    }

    /// The entity is what Shortcuts persists, so its id has to survive a round
    /// trip through a template's stored target.
    @Test
    func anEntityRoundTripsThroughATemplatesCachedTarget() {
        let original = SplitTargetEntity(ledger: Self.ledger(participants: [Self.me, Self.alex]), participant: Self.alex)
        let restored = SplitTargetEntity(cachedTarget: original.cachedTarget)

        #expect(restored.id == original.id)
        #expect(restored.zoneName == "Ledger-1")
        #expect(restored.participantID == "alex")
    }

    @Test
    func aWholeLedgerEntityIsIdentifiedByItsZoneAlone() {
        let entity = SplitTargetEntity(ledger: Self.ledger(participants: [Self.me, Self.alex]))
        #expect(entity.participantID == nil)
        #expect(entity.id == "Ledger-1")
        // Distinct from any one person on it, so the two can't collide in a
        // shortcut's stored pick.
        let person = SplitTargetEntity(ledger: Self.ledger(participants: [Self.me, Self.alex]), participant: Self.alex)
        #expect(person.id != entity.id)
    }
}
