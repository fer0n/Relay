//
//  LedgerBalancesTests.swift
//  RelayTests
//
//  `LedgerBalances` collapses what used to be a per-member walk of the
//  expense list into one pass, so the screens can read a cached figure
//  instead of deriving it in a view body. These cover the two things that
//  buys and the two ways a single pass can go wrong: a pair counted twice,
//  and a multi-payer expense rounded differently than one pair at a time.
//

import Foundation
import Testing
@testable import Relay

struct LedgerBalancesTests {
    /// Both of them fronted money, so the pair is reachable from either
    /// side of the walk — the case a naive pass double-counts.
    private static func groceries() -> LedgerExpense {
        LedgerExpense(
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
    }

    /// Odd cents on every side, to catch a rounding difference between the
    /// two paths rather than an arithmetic one.
    private static func awkward() -> LedgerExpense {
        LedgerExpense(
            title: "Taxi",
            costCents: 3337,
            currencyCode: "EUR",
            date: Date(),
            shares: [
                LedgerExpenseShare(participantID: "me", paidCents: 1113, owedCents: 1112),
                LedgerExpenseShare(participantID: "alex", paidCents: 1111, owedCents: 1113),
                LedgerExpenseShare(participantID: "sam", paidCents: 1113, owedCents: 1112),
            ]
        )
    }

    private static let everyone = ["me", "alex", "sam"]

    /// The whole point of the cache: it has to answer exactly what the
    /// per-pair function did, expense list and pair for pair.
    @Test
    func theOnePassMatchesThePerPairMath() {
        let expenses = [Self.groceries(), Self.awkward(), Self.groceries()]
        let balances = LedgerBalances(expenses: expenses)
        for me in Self.everyone {
            #expect(balances.net(for: me) == LedgerBalanceMath.netCents(for: me, expenses: expenses))
            for other in Self.everyone where other != me {
                #expect(balances.cents(me: me, other: other)
                    == LedgerBalanceMath.pairwiseCents(me: me, other: other, expenses: expenses))
            }
        }
    }

    /// A pair where both fronted money is reachable twice in one pass.
    @Test
    func aPairOfPayersIsCountedOnce() {
        let balances = LedgerBalances(expenses: [Self.groceries()])
        #expect(balances.cents(me: "me", other: "alex") == -500)
        #expect(balances.cents(me: "alex", other: "me") == 500)
    }

    @Test
    func pairwiseFiguresAreSymmetric() {
        let balances = LedgerBalances(expenses: [Self.groceries(), Self.awkward()])
        for me in Self.everyone {
            for other in Self.everyone where other != me {
                #expect(balances.cents(me: me, other: other) == -balances.cents(me: other, other: me))
            }
        }
    }

    @Test
    func someoneOffEveryExpenseReadsAsZero() {
        let balances = LedgerBalances(expenses: [Self.groceries()])
        #expect(balances.net(for: "robin") == 0)
        #expect(balances.cents(me: "me", other: "robin") == 0)
    }

    @Test
    func anEmptyLedgerOwesNothing() {
        #expect(LedgerBalances.empty.net(for: "me") == 0)
        #expect(LedgerBalances.empty.settlements.isEmpty)
    }

    /// A chain of debt is what simplifying is for: me → alex → sam becomes
    /// me → sam, and the middle pair reads as square.
    @Test
    func simplifyingCollapsesAChainOfDebt() {
        let expenses = [
            LedgerExpense.settlement(from: "alex", to: "me", cents: 1000, currencyCode: "EUR"),
            LedgerExpense.settlement(from: "sam", to: "alex", cents: 1000, currencyCode: "EUR"),
        ]
        let balances = LedgerBalances(expenses: expenses)
        // Unsimplified, each leg stands: alex owes me, sam owes alex.
        #expect(balances.cents(me: "me", other: "alex") == -1000)
        #expect(balances.cents(me: "alex", other: "sam") == -1000)

        #expect(balances.cents(me: "me", other: "alex", simplified: true) == 0)
        #expect(balances.cents(me: "alex", other: "sam", simplified: true) == 0)
        #expect(balances.cents(me: "me", other: "sam", simplified: true) == -1000)
    }

    /// Simplifying moves who owes whom around, never what anyone is up or
    /// down overall — otherwise it would be rewriting the balances, not
    /// rerouting them.
    @Test
    func simplifyingPreservesEveryNetPosition() {
        let expenses = [Self.groceries(), Self.awkward()]
        let balances = LedgerBalances(expenses: expenses)
        for me in Self.everyone {
            let simplified = Self.everyone
                .filter { $0 != me }
                .reduce(0) { $0 + balances.cents(me: me, other: $1, simplified: true) }
            #expect(simplified == balances.net(for: me))
            for other in Self.everyone where other != me {
                #expect(balances.cents(me: me, other: other, simplified: true)
                    == -balances.cents(me: other, other: me, simplified: true))
            }
        }
    }

    /// Precomputed alongside the rest, so the settle-up screen reads it
    /// rather than deriving it in a body.
    @Test
    func theSettlementPlanComesWithTheBalances() {
        let expenses = [Self.groceries()]
        let balances = LedgerBalances(expenses: expenses)
        #expect(balances.settlements
            == LedgerBalanceMath.settlements(netCents: LedgerBalanceMath.netCents(expenses: expenses)))
        #expect(!balances.settlements.isEmpty)
    }
}
