//
//  LedgerExpenseRequestTests.swift
//  RelayTests
//
//  What a ledger write leaves behind: the pending-queue payload and the
//  "Recent" row. It outlives the ledger it describes, so it carries names
//  rather than ids — and everything it reads off itself has to work for a
//  payload written by any version of the app.
//

import CloudKit
import Foundation
import Testing
@testable import Relay

struct LedgerExpenseRequestTests {
    private static let ledger = Ledger(
        zoneID: CKRecordZone.ID(zoneName: "Ledger-1", ownerName: "owner"),
        name: "Trip",
        currencyCode: "EUR",
        createdAt: Date(),
        isOwnedByCurrentUser: true,
        participants: [
            LedgerParticipant(id: "me", name: "Me", isCurrentUser: true, hasAccepted: true, isOwner: true),
            LedgerParticipant(id: "alex", name: "Alex Meyer", isCurrentUser: false, hasAccepted: true, isOwner: false),
            LedgerParticipant(id: "sam", name: nil, isCurrentUser: false, hasAccepted: false, isOwner: false),
        ]
    )

    private static func request(shares: [LedgerExpenseShare], title: String = "Dinner") -> LedgerExpenseRequest {
        LedgerExpenseRequest(
            expense: LedgerExpense(
                title: title,
                costCents: shares.reduce(0) { $0 + $1.paidCents },
                currencyCode: "EUR",
                date: Date(timeIntervalSince1970: 1_700_000_000),
                shares: shares
            ),
            ledger: ledger
        )
    }

    /// Names are frozen at write time: a "Recent" row months later shouldn't
    /// need the ledger, or the person, to still exist.
    @Test func aRequestCapturesTheNamesOfEveryoneOnTheLedger() {
        let request = Self.request(shares: [
            LedgerExpenseShare(participantID: "me", paidCents: 3000, owedCents: 1500),
            LedgerExpenseShare(participantID: "alex", paidCents: 0, owedCents: 1500),
        ])
        #expect(request.ledgerName == "Trip")
        #expect(request.participantNames["alex"] == "Alex Meyer")
        // Someone CloudKit won't name still gets the placeholder they're
        // shown by, rather than being left out.
        #expect(request.participantNames["sam"] == LedgerParticipant.invitedName)
    }

    /// Share order carries no meaning — a payload written by any version has
    /// its payer found by amount.
    @Test func thePayerIsFoundByAmountNotPosition() {
        let request = Self.request(shares: [
            LedgerExpenseShare(participantID: "alex", paidCents: 0, owedCents: 1500),
            LedgerExpenseShare(participantID: "me", paidCents: 3000, owedCents: 1500),
        ])
        #expect(request.payer?.participantID == "me")
        #expect(request.others.map(\.participantID) == ["alex"])
    }

    /// "Alex Meyer: 15,00 €" — what the queue and history rows show, and it
    /// must never bill the payer to themselves.
    @Test func theSummaryNamesEveryoneButThePayer() throws {
        let request = Self.request(shares: [
            LedgerExpenseShare(participantID: "me", paidCents: 3000, owedCents: 1000),
            LedgerExpenseShare(participantID: "alex", paidCents: 0, owedCents: 1000),
            LedgerExpenseShare(participantID: "sam", paidCents: 0, owedCents: 1000),
        ])
        let summary = try #require(request.participantsShareSummary)
        #expect(summary.contains("Alex Meyer"))
        #expect(summary.contains(LedgerParticipant.invitedName))
        #expect(!summary.contains(request.participantNames["me"] ?? "You"))
    }

    /// A share whose person isn't in the frozen name list is left out rather
    /// than shown under someone else's name.
    @Test func anUnnamedShareIsLeftOutOfTheSummary() {
        let request = LedgerExpenseRequest(
            zoneName: "Ledger-1",
            ledgerName: "Trip",
            expenseID: "e1",
            title: "Dinner",
            costCents: 2000,
            currencyCode: "EUR",
            shares: [
                LedgerExpenseShare(participantID: "me", paidCents: 2000, owedCents: 1000),
                LedgerExpenseShare(participantID: "ghost", paidCents: 0, owedCents: 1000),
            ],
            participantNames: ["me": "Me"],
            date: Date()
        )
        #expect(request.participantsShareSummary == nil)
    }

    /// A solo expense has nobody to list.
    @Test func aSplitWithNobodyHasNoSummary() {
        let request = Self.request(shares: [
            LedgerExpenseShare(participantID: "me", paidCents: 2000, owedCents: 2000),
        ])
        #expect(request.participantsShareSummary == nil)
        #expect(request.others.isEmpty)
    }

    /// Renaming a frozen history entry to match an edited Payee mapping must
    /// change the title and nothing else — losing `isSettlement` there would
    /// resync a payment as an ordinary expense.
    @Test func renamingKeepsEverythingButTheTitle() {
        let settlement = LedgerExpenseRequest(
            expense: LedgerExpense.settlement(from: "me", to: "alex", cents: 1200, currencyCode: "EUR"),
            ledger: Self.ledger
        )
        let renamed = settlement.withTitle("Repaid Alex")

        #expect(renamed.title == "Repaid Alex")
        #expect(renamed.isSettlement == true)
        #expect(renamed.asExpense.isSettlement)
        #expect(renamed.shares == settlement.shares)
        #expect(renamed.expenseID == settlement.expenseID)
        #expect(renamed.zoneName == settlement.zoneName)
        #expect(renamed.participantNames == settlement.participantNames)
        #expect(renamed.date == settlement.date)
        #expect(renamed.costCents == settlement.costCents)
        #expect(renamed.currencyCode == settlement.currencyCode)
    }

    /// The queue saves `asExpense`, and `LedgerService.save` refuses anything
    /// unbalanced — so a payload that doesn't total is a write that can never
    /// drain.
    @Test func whatTheQueueWillSaveIsStillBalanced() {
        let request = Self.request(shares: [
            LedgerExpenseShare(participantID: "me", paidCents: 3000, owedCents: 1000),
            LedgerExpenseShare(participantID: "alex", paidCents: 0, owedCents: 2000),
        ])
        #expect(request.asExpense.isBalanced)
    }

    /// A payload queued before the flag existed decodes with it absent, and
    /// reads as the ordinary expense it was.
    @Test func aPayloadFromBeforeTheSettlementFlagStillDecodes() throws {
        let json = Data("""
        {
          "zoneName": "Ledger-1",
          "ledgerName": "Trip",
          "expenseID": "e1",
          "title": "Dinner",
          "costCents": 2000,
          "currencyCode": "EUR",
          "shares": [
            { "participantID": "me", "paidCents": 2000, "owedCents": 1000 },
            { "participantID": "alex", "paidCents": 0, "owedCents": 1000 }
          ],
          "participantNames": { "alex": "Alex Meyer" },
          "date": 0
        }
        """.utf8)
        let request = try JSONDecoder().decode(LedgerExpenseRequest.self, from: json)
        #expect(request.isSettlement == nil)
        #expect(!request.asExpense.isSettlement)
        #expect(request.asExpense.isBalanced)
    }
}
