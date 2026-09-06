//
//  OfflineLedgerQueueTests.swift
//  RelayTests
//
//  Covers the two silent ways an offline ledger add regresses: CloudKit's
//  own error codes not being read as "no network" (so the write is thrown
//  away instead of queued), and the queued payload losing a field on the
//  round trip (so it syncs back as something else).
//

import CloudKit
import Foundation
import Testing
@testable import Relay

struct OfflineLedgerQueueTests {
    /// CKErrorDomain 3 — what a `modifyRecords` actually throws in airplane
    /// mode. Read as a plain error it would be surfaced as a permanent
    /// failure and the expense dropped.
    @Test func cloudKitNetworkErrorsAreConnectivityFailures() {
        for code in [CKError.Code.networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited] {
            #expect(CKError(code) .isConnectivityFailure, "\(code) should queue")
        }
    }

    /// A partial failure names the real code per item, so the wrapper alone
    /// says nothing.
    @Test func partialFailureFollowsItsItemErrors() {
        let recordID = CKRecord.ID(recordName: "expense")
        let offline = CKError(
            .partialFailure,
            userInfo: [CKPartialErrorsByItemIDKey: [recordID: CKError(.networkUnavailable)]]
        )
        #expect(offline.isConnectivityFailure)

        let rejected = CKError(
            .partialFailure,
            userInfo: [CKPartialErrorsByItemIDKey: [recordID: CKError(.serverRecordChanged)]]
        )
        #expect(!rejected.isConnectivityFailure)
        // An empty one names nothing to retry on.
        #expect(!CKError(.partialFailure).isConnectivityFailure)
    }

    /// Retrying these would fail the same way forever, so they must stay out.
    @Test func rejectionsAreNotConnectivityFailures() {
        for code in [CKError.Code.notAuthenticated, .permissionFailure, .serverRecordChanged, .invalidArguments] {
            #expect(!CKError(code).isConnectivityFailure, "\(code) should surface")
        }
    }

    @Test func urlErrorsStillClassify() {
        #expect(URLError(.notConnectedToInternet).isConnectivityFailure)
        #expect(!URLError(.badServerResponse).isConnectivityFailure)
    }

    private static let ledger = Ledger(
        zoneID: CKRecordZone.ID(zoneName: "zone", ownerName: "owner"),
        name: "Trip",
        currencyCode: "EUR",
        createdAt: Date(),
        isOwnedByCurrentUser: true,
        participants: [
            LedgerParticipant(id: "me", name: "Me", isCurrentUser: true, hasAccepted: true, isOwner: true),
            LedgerParticipant(id: "alex", name: "Alex", isCurrentUser: false, hasAccepted: true, isOwner: false),
        ]
    )

    /// What the queue saves is `asExpense`, so anything the request drops is
    /// dropped from the record too. `createdBy`/`createdAt` are deliberately
    /// not compared: both are CloudKit's to assign on the way in, and a
    /// locally built expense has neither either.
    @Test func queuedCustomSplitSurvivesTheRoundTrip() throws {
        let expense = LedgerExpense(
            title: "Taxi",
            costCents: 3000,
            currencyCode: "EUR",
            date: Date(timeIntervalSince1970: 1_700_000_000),
            shares: [
                LedgerExpenseShare(participantID: "me", paidCents: 3000, owedCents: 500),
                LedgerExpenseShare(participantID: "alex", paidCents: 0, owedCents: 2500),
            ]
        )
        let request = LedgerExpenseRequest(expense: expense, ledger: Self.ledger)
        let decoded = try JSONDecoder().decode(
            LedgerExpenseRequest.self,
            from: JSONEncoder().encode(request)
        )
        let restored = decoded.asExpense
        #expect(restored.id == expense.id)
        #expect(restored.title == expense.title)
        #expect(restored.costCents == expense.costCents)
        #expect(restored.currencyCode == expense.currencyCode)
        #expect(restored.date == expense.date)
        // The custom part: an uneven split has to come back uneven.
        #expect(restored.shares == expense.shares)
        #expect(!restored.isSettlement)
        #expect(restored.isBalanced)
    }

    /// A settlement that came back as an ordinary expense would put "You
    /// paid" on a row that should name who was paid.
    @Test func queuedSettlementStaysASettlement() {
        let settlement = LedgerExpense.settlement(from: "me", to: "alex", cents: 1200, currencyCode: "EUR")
        let request = LedgerExpenseRequest(expense: settlement, ledger: Self.ledger)
        #expect(request.asExpense.isSettlement)
    }

    /// Operations queued before `recordsHistory` existed still decode, and
    /// still record history the way they did when they were queued.
    @Test func olderQueuedOperationsStillRecordHistory() throws {
        let json = Data("""
        {
          "id": "\(UUID().uuidString)",
          "queuedAt": 0,
          "summary": "12.00 at Bakery",
          "attemptCount": 0,
          "payload": {
            "ynabTransaction": {
              "_0": {
                "accountId": "acct",
                "date": "2026-07-22",
                "amount": -12000,
                "payeeName": "Bakery",
                "cleared": "cleared",
                "approved": true
              }
            }
          }
        }
        """.utf8)
        let operation = try JSONDecoder().decode(PendingOperation.self, from: json)
        #expect(operation.shouldRecordHistory)
        #expect(operation.recordsHistory == nil)
    }
}
