//
//  SplitwiseExpenseRequestDecodingTests.swift
//  RelayTests
//
//  SplitwiseExpenseRequest is persisted — in the offline queue and in every
//  transaction history entry — so widening it from "payer plus one friend" to
//  a participant list can't be allowed to orphan the payloads already on disk.
//  One failed decode fails the whole file, taking the rest of the queue or
//  history with it.
//

import Foundation
import Testing
@testable import Relay

struct SplitwiseExpenseRequestDecodingTests {
    /// Exactly what an older build wrote: four flat fields, no participants,
    /// no group.
    private static let legacyJSON = """
    {
      "costCents": 4500,
      "description": "Restaurant",
      "currencyCode": "EUR",
      "payerUserId": 999,
      "payerOwedCents": 2250,
      "friendUserId": 42,
      "friendOwedCents": 2250,
      "date": "2026-07-21"
    }
    """

    @Test
    func aPayloadWrittenBeforeParticipantsExistedStillDecodes() throws {
        let request = try JSONDecoder().decode(SplitwiseExpenseRequest.self, from: Data(Self.legacyJSON.utf8))

        #expect(request.costCents == 4500)
        #expect(request.date == "2026-07-21")
        // No group_id was stored, and a personal expense is exactly group 0.
        #expect(request.groupId == 0)
        #expect(request.participants.count == 2)
        #expect(request.payerUserId == 999)
        #expect(request.payerOwedCents == 2250)
        #expect(request.others.map(\.userId) == [42])
        #expect(request.others.map(\.owedCents) == [2250])
        // The payer fronts the whole cost, which the old shape left implicit.
        #expect(request.participants.first?.paidCents == 4500)
    }

    @Test
    func aMultiParticipantGroupExpenseRoundTrips() throws {
        let request = SplitwiseExpenseRequest(
            costCents: 3000,
            description: "Groceries",
            currencyCode: "EUR",
            groupId: 77,
            participants: [
                .init(userId: 1, paidCents: 3000, owedCents: 1000),
                .init(userId: 2, paidCents: 0, owedCents: 1000),
                .init(userId: 3, paidCents: 0, owedCents: 1000),
            ],
            date: nil
        )

        let decoded = try JSONDecoder().decode(
            SplitwiseExpenseRequest.self,
            from: JSONEncoder().encode(request)
        )

        #expect(decoded.groupId == 77)
        #expect(decoded.participants == request.participants)
        #expect(decoded.others.count == 2)
    }

    @Test
    func everyParticipantIsFlattenedTheWaySplitwiseWantsThem() {
        let request = SplitwiseExpenseRequest(
            costCents: 3000,
            description: "Groceries",
            currencyCode: "EUR",
            groupId: 77,
            participants: [
                .init(userId: 1, paidCents: 3000, owedCents: 1000),
                .init(userId: 2, paidCents: 0, owedCents: 1000),
                .init(userId: 3, paidCents: 0, owedCents: 1000),
            ],
            date: nil
        )

        let object = request.asJSONObject
        #expect(object["group_id"] as? Int == 77)
        #expect(object["users__0__user_id"] as? Int == 1)
        #expect(object["users__0__paid_share"] as? String == "30.00")
        #expect(object["users__0__owed_share"] as? String == "10.00")
        #expect(object["users__2__user_id"] as? Int == 3)
        #expect(object["users__2__paid_share"] as? String == "0.00")
        #expect(object["users__2__owed_share"] as? String == "10.00")
        // Absent rather than sent empty — Splitwise reads a missing date as now.
        #expect(object["date"] == nil)
    }

    @Test
    func theSingleFriendConvenienceStillBuildsAPersonalExpense() {
        let request = SplitwiseExpenseRequest(
            costCents: 1000,
            description: "Coffee",
            currencyCode: "EUR",
            payerUserId: 1,
            payerOwedCents: 400,
            friendUserId: 2,
            friendOwedCents: 600,
            date: nil
        )

        #expect(request.groupId == 0)
        #expect(request.asJSONObject["group_id"] as? Int == 0)
        #expect(request.others.map(\.owedCents) == [600])
    }
}
