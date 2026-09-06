//
//  LedgerBalanceMathTests.swift
//  RelayTests
//
//  Splitwise computes balances and simplified debts server-side; an iCloud
//  ledger has to derive both from the expense records themselves, so these
//  cover the arithmetic nobody else is checking: that nets sum to zero, that a
//  settle-up plan actually clears everyone, and that a pairwise balance
//  ignores what third parties owe.
//

import Foundation
import Testing
@testable import Relay

struct LedgerBalanceMathTests {
    /// Three people, one payer, split evenly.
    private static func dinner() -> LedgerExpense {
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
        )
    }

    @Test
    func netPositionsAlwaysCancelOut() {
        let net = LedgerBalanceMath.netCents(expenses: [Self.dinner()])
        #expect(net["me"] == 2000)
        #expect(net["alex"] == -1000)
        #expect(net["sam"] == -1000)
        #expect(net.values.reduce(0, +) == 0)
    }

    @Test
    func aParticipantWithNoExpensesStillAppearsAtZero() {
        let net = LedgerBalanceMath.netCents(expenses: [Self.dinner()], participants: ["me", "alex", "sam", "robin"])
        #expect(net["robin"] == 0)
    }

    @Test
    func pairwiseBalanceIgnoresWhatThirdPartiesOwe() {
        // Alex owes 10 of the 30 dinner; Sam's 10 is none of Alex's business.
        let cents = LedgerBalanceMath.pairwiseCents(me: "me", other: "alex", expenses: [Self.dinner()])
        #expect(cents == 1000)
    }

    @Test
    func pairwiseBalanceIsSymmetric() {
        let mine = LedgerBalanceMath.pairwiseCents(me: "me", other: "alex", expenses: [Self.dinner()])
        let theirs = LedgerBalanceMath.pairwiseCents(me: "alex", other: "me", expenses: [Self.dinner()])
        #expect(mine == -theirs)
    }

    /// Two payers on one expense: each debtor's share is attributed to them in
    /// proportion to what they fronted.
    @Test
    func pairwiseBalanceSplitsADebtAcrossSeveralPayers() {
        let expense = LedgerExpense(
            title: "Groceries",
            costCents: 4000,
            currencyCode: "EUR",
            date: Date(),
            shares: [
                LedgerExpenseShare(participantID: "me", paidCents: 3000, owedCents: 2000),
                LedgerExpenseShare(participantID: "alex", paidCents: 1000, owedCents: 0),
                LedgerExpenseShare(participantID: "sam", paidCents: 0, owedCents: 2000),
            ]
        )
        // Sam owes 20.00, and I fronted three quarters of the bill.
        #expect(LedgerBalanceMath.pairwiseCents(me: "me", other: "sam", expenses: [expense]) == 1500)
        #expect(LedgerBalanceMath.pairwiseCents(me: "alex", other: "sam", expenses: [expense]) == 500)
        // I owe 20.00 of my own bill, a quarter of which Alex fronted.
        #expect(LedgerBalanceMath.pairwiseCents(me: "me", other: "alex", expenses: [expense]) == -500)
    }

    @Test
    func settlementsClearEveryBalance() {
        let net = LedgerBalanceMath.netCents(expenses: [Self.dinner()])
        let settlements = LedgerBalanceMath.settlements(netCents: net)
        var settled = net
        for settlement in settlements {
            settled[settlement.from, default: 0] += settlement.cents
            settled[settlement.to, default: 0] -= settlement.cents
        }
        #expect(settled.values.allSatisfy { $0 == 0 })
        #expect(settlements.allSatisfy { $0.cents > 0 })
    }

    /// The point of simplifying: A owes B and B owes C nets out to A paying C,
    /// leaving B out of it entirely.
    @Test
    func settlementsCollapseChainsOfDebt() {
        let settlements = LedgerBalanceMath.settlements(netCents: ["a": -1000, "b": 0, "c": 1000])
        #expect(settlements == [LedgerSettlement(from: "a", to: "c", cents: 1000)])
    }

    @Test
    func anAlreadySettledLedgerNeedsNoTransfers() {
        #expect(LedgerBalanceMath.settlements(netCents: ["a": 0, "b": 0]).isEmpty)
    }

    @Test
    func sharesFromAnEvenSplitTotalTheCostExactly() {
        let shares = LedgerBalanceMath.shares(
            costCents: 1000,
            payerID: "me",
            participantIDs: ["me", "alex", "sam"],
            allocation: .equal
        )
        #expect(shares?.count == 3)
        #expect(shares?.reduce(0) { $0 + $1.owedCents } == 1000)
        #expect(shares?.reduce(0) { $0 + $1.paidCents } == 1000)
        #expect(shares?.first { $0.participantID == "me" }?.paidCents == 1000)
    }

    @Test
    func sharesRefuseASplitWithNobodyElseOnIt() {
        #expect(LedgerBalanceMath.shares(
            costCents: 1000,
            payerID: "me",
            participantIDs: ["me"],
            allocation: .equal
        ) == nil)
    }

    @Test
    func sharesFromAnOwnShareLeaveTheRestToEveryoneElse() {
        let shares = LedgerBalanceMath.shares(
            costCents: 3000,
            payerID: "me",
            participantIDs: ["me", "alex", "sam"],
            allocation: .ownShare(cents: 1000)
        )
        #expect(shares?.first { $0.participantID == "me" }?.owedCents == 1000)
        #expect(shares?.first { $0.participantID == "alex" }?.owedCents == 1000)
        #expect(shares?.first { $0.participantID == "sam" }?.owedCents == 1000)
    }

    @Test
    func aBuiltExpenseIsBalanced() {
        let shares = LedgerBalanceMath.shares(
            costCents: 1234,
            payerID: "me",
            participantIDs: ["me", "alex"],
            allocation: .equal
        )
        let expense = LedgerExpense(
            title: "Coffee",
            costCents: 1234,
            currencyCode: "EUR",
            date: Date(),
            shares: shares ?? []
        )
        #expect(expense.isBalanced)
    }

    @Test
    func anExpenseWhoseSharesDontTotalIsRejected() {
        let expense = LedgerExpense(
            title: "Wrong",
            costCents: 1000,
            currencyCode: "EUR",
            date: Date(),
            shares: [LedgerExpenseShare(participantID: "me", paidCents: 1000, owedCents: 400)]
        )
        #expect(!expense.isBalanced)
    }
}
