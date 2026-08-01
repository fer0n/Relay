//
//  SplitwiseExpenseEditTests.swift
//  RelayTests
//
//  Covers editing an expense that already exists on Splitwise
//  (SplitwiseExpenseDetailView): the share arithmetic that has to keep the
//  parts adding up to the total exactly — Splitwise rejects an expense where
//  they don't — the `update_expense` payload built from it, and the tolerant
//  decoding of the `groupId` that payload has to carry back.
//

import Foundation
import Testing
@testable import Relay

struct SplitwiseShareMathTests {
    @Test
    func parsesEitherDecimalSeparator() {
        #expect(SplitwiseShareMath.cents("12.50") == 1250)
        #expect(SplitwiseShareMath.cents("12,50") == 1250)
        #expect(SplitwiseShareMath.cents(" 8 ") == 800)
    }

    @Test
    func rejectsUnusableAmounts() {
        #expect(SplitwiseShareMath.cents("") == nil)
        #expect(SplitwiseShareMath.cents("abc") == nil)
        // A share can be zero, but never negative.
        #expect(SplitwiseShareMath.cents("-1") == nil)
        #expect(SplitwiseShareMath.cents("0") == 0)
    }

    @Test
    func splitsEvenlyWhenThereIsNoRatioToPreserve() {
        #expect(SplitwiseShareMath.ratios(of: [0, 0]) == [0.5, 0.5])
        #expect(SplitwiseShareMath.ratios(of: []).isEmpty)
    }

    /// What a changed total divides along until a share is edited by hand.
    @Test
    func splitsANewTotalEqually() {
        #expect(SplitwiseShareMath.evenRatios(count: 0).isEmpty)
        #expect(SplitwiseShareMath.distribute(totalCents: 3000, ratios: SplitwiseShareMath.evenRatios(count: 2)) == [1500, 1500])
        #expect(SplitwiseShareMath.distribute(totalCents: 3000, ratios: SplitwiseShareMath.evenRatios(count: 4)) == [750, 750, 750, 750])
    }

    @Test
    func keepsProportionsAfterAShareIsEditedByHand() {
        let ratios = SplitwiseShareMath.ratios(of: [20, 5])
        #expect(SplitwiseShareMath.distribute(totalCents: 5000, ratios: ratios) == [4000, 1000])
    }

    /// The case Splitwise would reject: an odd total split evenly rounds to
    /// two halves that don't add back up, so the leftover cent has to land
    /// somewhere.
    @Test
    func partsAlwaysAddUpToTheTotal() {
        let evenSplit = SplitwiseShareMath.distribute(totalCents: 1001, ratios: [0.5, 0.5])
        #expect(evenSplit.reduce(0, +) == 1001)

        let threeWay = SplitwiseShareMath.distribute(totalCents: 1000, ratios: SplitwiseShareMath.ratios(of: [1, 1, 1]))
        #expect(threeWay.reduce(0, +) == 1000)
        // The remainder goes on the largest part, so no share is left at 0
        // by rounding and the small ones stay put.
        #expect(threeWay.sorted() == [333, 333, 334])
    }

    /// What the paid amounts are saved as: the detail view sends them derived
    /// from their ratios rather than read off the fields, so they're
    /// guaranteed to add up to the cost. That only holds up if the round trip
    /// gives back exactly what was typed — including after the payer row is
    /// handed to someone else, which leaves the previous payer at zero.
    @Test
    func derivingPaidAmountsFromTheirRatiosReproducesThem() {
        let solePayer = SplitwiseShareMath.ratios(of: [0, 42])
        #expect(SplitwiseShareMath.distribute(totalCents: 4200, ratios: solePayer) == [0, 4200])

        let twoPayers = SplitwiseShareMath.ratios(of: [30, 20])
        #expect(SplitwiseShareMath.distribute(totalCents: 5000, ratios: twoPayers) == [3000, 2000])
    }

    @Test
    func roundTripsAnAmountThroughTextUnchanged() {
        let cents = SplitwiseShareMath.cents(fromAmount: 42.35)
        #expect(cents == 4235)
        #expect(SplitwiseShareMath.cents(SplitwiseShareMath.text(fromCents: cents)) == 4235)
    }
}

struct SplitwiseExpenseUpdateRequestTests {
    private static let request = SplitwiseExpenseUpdateRequest(
        costCents: 4200,
        description: "Groceries",
        currencyCode: "EUR",
        groupId: 7,
        users: [
            .init(userId: 1, paidCents: 4200, owedCents: 1500),
            .init(userId: 2, paidCents: 0, owedCents: 2700),
        ]
    )

    @Test
    func flattensEveryParticipantSplitwiseWay() {
        let object = Self.request.asJSONObject

        #expect(object["cost"] as? String == "42.00")
        #expect(object["description"] as? String == "Groceries")
        #expect(object["users__0__user_id"] as? Int == 1)
        #expect(object["users__0__paid_share"] as? String == "42.00")
        #expect(object["users__0__owed_share"] as? String == "15.00")
        #expect(object["users__1__user_id"] as? Int == 2)
        #expect(object["users__1__paid_share"] as? String == "0.00")
        #expect(object["users__1__owed_share"] as? String == "27.00")
    }

    /// A group expense must stay in its group — `update_expense` reads a
    /// zero/missing `group_id` as "personal" and would move it out.
    @Test
    func keepsTheExpenseInItsGroup() {
        #expect(Self.request.asJSONObject["group_id"] as? Int == 7)
    }

    /// The date isn't editable on this screen, and update_expense leaves out
    /// what isn't sent — sending a date would risk rewriting it.
    @Test
    func omitsFieldsItDoesNotEdit() {
        #expect(Self.request.asJSONObject["date"] == nil)
    }

    /// Splitwise wants a `.` decimal separator no matter what the device's
    /// locale uses for display, so the payload must not go through a
    /// locale-aware formatter.
    @Test
    func writesAmountsWithADotRegardlessOfLocale() {
        let cost = Self.request.asJSONObject["cost"] as? String
        #expect(cost?.contains(",") == false)
    }
}

struct SplitwiseExpenseDecodingTests {
    /// An expense cache written before `groupId` existed (see
    /// SplitwiseExpenseCacheStore, and WalletTransactionConfigDecodingTests
    /// for the shape of bug this protects against): the field is Optional, so
    /// the synthesized decoder uses `decodeIfPresent` and the whole cached
    /// history still loads instead of being silently dropped.
    @Test
    func decodesExpenseWrittenBeforeGroupIdExisted() throws {
        let json = """
        {
          "id": 99,
          "description": "Groceries",
          "cost": "42.00",
          "currencyCode": "EUR",
          "date": 800000000,
          "users": [
            { "userId": 1, "paidShare": "42.00", "netBalance": "21.00" }
          ]
        }
        """
        let expense = try JSONDecoder().decode(SplitwiseExpense.self, from: Data(json.utf8))

        #expect(expense.groupId == nil)
        #expect(expense.users.first?.owedShare == 21)
    }

    @Test
    func decodesGroupIdFromALiveResponse() throws {
        let json = """
        {
          "id": 99,
          "description": "Groceries",
          "cost": "42.00",
          "currency_code": "EUR",
          "date": "2026-07-21T05:00:00Z",
          "group_id": 7,
          "users": [
            { "user_id": 1, "paid_share": "42.00", "net_balance": "21.00" }
          ]
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        let expense = try decoder.decode(SplitwiseExpense.self, from: Data(json.utf8))

        #expect(expense.groupId == 7)
    }
}
