//
//  LedgerSettlementTests.swift
//  RelayTests
//
//  Settling up on a ledger isn't a separate concept — handing someone money
//  is an expense they owe in full, so it goes through the same records and
//  the same arithmetic as everything else. These pin that down: recording the
//  plan's payments has to actually clear the balances, or the suggestions on
//  the record-payment screen would keep proposing transfers that never take
//  effect.
//

import Foundation
import Testing
@testable import Relay

struct LedgerSettlementTests {
    private static func applying(_ settlements: [LedgerSettlement], to expenses: [LedgerExpense]) -> [LedgerExpense] {
        expenses + settlements.map {
            LedgerExpense.settlement(from: $0.from, to: $0.to, cents: $0.cents, currencyCode: "EUR")
        }
    }

    private static let dinner = LedgerExpense(
        title: "Dinner",
        costCents: 3000,
        currencyCode: "EUR",
        date: Date(),
        shares: [
            LedgerExpenseShare(participantID: "me", paidCents: 3000, owedCents: 1000),
            LedgerExpenseShare(participantID: "alex", paidCents: 0, owedCents: 1000),
            LedgerExpenseShare(participantID: "sam", paidCents: 0, owedCents: 1000),
        ]
    )

    @Test
    func aSettlementIsAValidExpense() {
        let payment = LedgerExpense.settlement(from: "alex", to: "me", cents: 1000, currencyCode: "EUR")
        #expect(payment.isBalanced)
        #expect(payment.isSettlement)
    }

    @Test
    func aSettlementMovesBothBalancesByTheAmountPaid() {
        let payment = LedgerExpense.settlement(from: "alex", to: "me", cents: 1000, currencyCode: "EUR")
        #expect(payment.netCents(for: "alex") == 1000)
        #expect(payment.netCents(for: "me") == -1000)
    }

    /// The whole point: carrying out the plan the settle-up section shows has
    /// to leave nothing left to settle.
    @Test
    func recordingTheWholePlanSettlesTheLedger() {
        let expenses = [Self.dinner]
        let plan = LedgerBalanceMath.settlements(netCents: LedgerBalanceMath.netCents(expenses: expenses))
        let after = LedgerBalanceMath.netCents(expenses: Self.applying(plan, to: expenses))

        #expect(after.values.allSatisfy { $0 == 0 })
        #expect(LedgerBalanceMath.settlements(netCents: after).isEmpty)
    }

    @Test
    func recordingOnePaymentLeavesTheRestOutstanding() {
        let expenses = [Self.dinner]
        let plan = LedgerBalanceMath.settlements(netCents: LedgerBalanceMath.netCents(expenses: expenses))
        let first = try! #require(plan.first)
        let after = LedgerBalanceMath.netCents(expenses: Self.applying([first], to: expenses))

        #expect(after[first.from] == 0)
        #expect(after.values.reduce(0, +) == 0)
        #expect(LedgerBalanceMath.settlements(netCents: after).count == plan.count - 1)
    }

    /// A settlement is between exactly two people, so it should move their
    /// pairwise balance by the full amount and nobody else's.
    @Test
    func aSettlementClearsThePairwiseBalanceItWasFor() {
        let expenses = [Self.dinner]
        #expect(LedgerBalanceMath.pairwiseCents(me: "me", other: "alex", expenses: expenses) == 1000)

        let settled = Self.applying([LedgerSettlement(from: "alex", to: "me", cents: 1000)], to: expenses)
        #expect(LedgerBalanceMath.pairwiseCents(me: "me", other: "alex", expenses: settled) == 0)
        // Sam wasn't part of that payment.
        #expect(LedgerBalanceMath.pairwiseCents(me: "me", other: "sam", expenses: settled) == 1000)
    }
}
