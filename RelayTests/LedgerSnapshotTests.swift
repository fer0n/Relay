//
//  LedgerSnapshotTests.swift
//  RelayTests
//
//  The on-disk render cache. It's disposable, but it's also the only thing
//  the first frame after launch has to draw, and every failure mode here is
//  silent: a zone rebuilt with the wrong owner points at the wrong database,
//  and one strictly-decoded field added later empties the whole cache for
//  everyone who already has one.
//

import CloudKit
import Foundation
import Testing
@testable import Relay

struct LedgerSnapshotTests {
    private static func ledger(
        zoneName: String = "Ledger-1",
        ownerName: String = CKCurrentUserDefaultName,
        isOwned: Bool = true,
        simplifies: Bool = true
    ) -> Ledger {
        Ledger(
            zoneID: CKRecordZone.ID(zoneName: zoneName, ownerName: ownerName),
            name: "Trip",
            currencyCode: "EUR",
            createdAt: Date(timeIntervalSince1970: 1_600_000_000),
            isOwnedByCurrentUser: isOwned,
            participants: [
                LedgerParticipant(id: "me", name: "Me", isCurrentUser: true, hasAccepted: true, isOwner: isOwned),
                LedgerParticipant(
                    id: "alex",
                    name: "Alex",
                    isCurrentUser: false,
                    hasAccepted: true,
                    isOwner: !isOwned,
                    imageData: Data([0xFF, 0xD8, 0xFF]),
                    hasProfile: true
                ),
            ],
            simplifiesDebts: simplifies
        )
    }

    private static func roundTrip(_ snapshot: LedgerSnapshot) throws -> LedgerSnapshot {
        try JSONDecoder().decode(LedgerSnapshot.self, from: JSONEncoder().encode(snapshot))
    }

    /// `CKRecordZone.ID` isn't Codable, so the zone is taken apart and put
    /// back together — and a ledger someone else owns lives in a zone named
    /// after *them*. Rebuilt with the wrong owner it would be looked up in
    /// the wrong database and simply not be there.
    @Test func aSharedLedgersZoneOwnerSurvives() throws {
        let shared = Self.ledger(zoneName: "Ledger-2", ownerName: "alex", isOwned: false)
        let restored = try Self.roundTrip(
            LedgerSnapshot(ledgers: [shared], expenses: [:], currentUserID: "me")
        ).ledgers[0].ledger

        #expect(restored.zoneID == shared.zoneID)
        #expect(restored.zoneID.ownerName == "alex")
        #expect(!restored.isOwnedByCurrentUser)
    }

    @Test func aLedgerRoundTripsWithItsParticipants() throws {
        let original = Self.ledger()
        let restored = try Self.roundTrip(
            LedgerSnapshot(ledgers: [original], expenses: [:], currentUserID: "me")
        ).ledgers[0].ledger

        #expect(restored == original)
        // Avatars ride along, or every launch draws initials until the first
        // refresh lands.
        #expect(restored.participant(id: "alex")?.imageData != nil)
        #expect(restored.participant(id: "alex")?.hasProfile == true)
    }

    /// The setting is the ledger's, not the device's, and it changes what
    /// every balance on the first frame says.
    @Test func theSimplifyDebtsSettingSurvives() throws {
        let off = try Self.roundTrip(
            LedgerSnapshot(ledgers: [Self.ledger(simplifies: false)], expenses: [:], currentUserID: "me")
        ).ledgers[0].ledger
        #expect(!off.simplifiesDebts)
    }

    /// A cache written before the setting existed has no such key, and those
    /// ledgers were simplifying.
    @Test func aStoredLedgerFromBeforeTheSettingStillDecodes() throws {
        let json = Data("""
        {
          "zoneName": "Ledger-1",
          "zoneOwnerName": "__defaultOwner__",
          "name": "Trip",
          "currencyCode": "EUR",
          "createdAt": 0,
          "isOwnedByCurrentUser": true,
          "participants": []
        }
        """.utf8)
        let stored = try JSONDecoder().decode(LedgerSnapshot.StoredLedger.self, from: json)
        #expect(stored.ledger.simplifiesDebts)
    }

    /// Keyed by zone name in the snapshot exactly as in the store, since
    /// that's the key that survives the owner-name difference between the two
    /// database views of the same zone.
    @Test func expensesComeBackUnderTheirZone() throws {
        let expense = LedgerExpense(
            title: "Dinner",
            costCents: 3000,
            currencyCode: "EUR",
            date: Date(timeIntervalSince1970: 1_700_000_000),
            shares: [
                LedgerExpenseShare(participantID: "me", paidCents: 3000, owedCents: 1500),
                LedgerExpenseShare(participantID: "alex", paidCents: 0, owedCents: 1500),
            ]
        )
        let settlement = LedgerExpense.settlement(
            from: "alex",
            to: "me",
            cents: 1500,
            currencyCode: "EUR",
            date: Date(timeIntervalSince1970: 1_700_100_000)
        )
        let restored = try Self.roundTrip(LedgerSnapshot(
            ledgers: [Self.ledger()],
            expenses: ["Ledger-1": [expense, settlement]],
            currentUserID: "me"
        ))

        #expect(restored.currentUserID == "me")
        #expect(restored.expenses["Ledger-1"] == [expense, settlement])
        // A settlement read back as an ordinary expense would relabel the row
        // it draws.
        #expect(restored.expenses["Ledger-1"]?.last?.isSettlement == true)
    }

    /// The balances the cached expenses draw have to be the ones the live
    /// list would: the cache is what's on screen until a refresh lands.
    @Test func cachedExpensesDeriveTheSameBalances() throws {
        let expenses = [
            LedgerExpense(
                title: "Dinner",
                costCents: 3000,
                currencyCode: "EUR",
                date: Date(),
                shares: [
                    LedgerExpenseShare(participantID: "me", paidCents: 3000, owedCents: 1000),
                    LedgerExpenseShare(participantID: "alex", paidCents: 0, owedCents: 1000),
                    LedgerExpenseShare(participantID: "sam", paidCents: 0, owedCents: 1000),
                ]
            ),
        ]
        let restored = try Self.roundTrip(
            LedgerSnapshot(ledgers: [Self.ledger()], expenses: ["Ledger-1": expenses], currentUserID: "me")
        ).expenses["Ledger-1"] ?? []

        #expect(LedgerBalances(expenses: restored).netCents == LedgerBalances(expenses: expenses).netCents)
    }

    /// A cache written by a newer build carries keys this one doesn't know —
    /// a TestFlight rollback, or the two builds on one iCloud account. Ignored
    /// rather than fatal, or the downgraded device draws nothing until its
    /// first refresh lands.
    @Test func aStoredLedgerWithUnknownKeysStillDecodes() throws {
        let json = Data("""
        {
          "zoneName": "Ledger-1",
          "zoneOwnerName": "__defaultOwner__",
          "name": "Trip",
          "currencyCode": "EUR",
          "createdAt": 0,
          "isOwnedByCurrentUser": true,
          "participants": [],
          "simplifiesDebts": false,
          "somethingAddedLater": "value"
        }
        """.utf8)
        let stored = try JSONDecoder().decode(LedgerSnapshot.StoredLedger.self, from: json)
        #expect(stored.ledger.name == "Trip")
        #expect(!stored.ledger.simplifiesDebts)
    }

    /// Who wrote an expense is what tells the change notifier whose write to
    /// announce, and after a cold launch the cache is the only copy there is.
    @Test func theAuthorOfACachedExpenseSurvives() throws {
        let expense = LedgerExpense(
            title: "Dinner",
            costCents: 1000,
            currencyCode: "EUR",
            date: Date(timeIntervalSince1970: 0),
            shares: [LedgerExpenseShare(participantID: "alex", paidCents: 1000, owedCents: 1000)],
            createdBy: "alex",
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let restored = try Self.roundTrip(
            LedgerSnapshot(ledgers: [Self.ledger()], expenses: ["Ledger-1": [expense]], currentUserID: "me")
        ).expenses["Ledger-1"]?.first

        #expect(restored?.createdBy == "alex")
        #expect(restored?.createdAt == expense.createdAt)
    }
}
