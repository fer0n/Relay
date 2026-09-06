//
//  LedgerBalanceMath.swift
//  Relay
//
//  Balances derived from the expense list: each person's net position, and
//  the "A pays B" transfers that clear everyone at once.
//

import Foundation

/// One leg of a settle-up plan: `from` pays `to`.
nonisolated struct LedgerSettlement: Equatable, Hashable, Sendable {
    let from: String
    let to: String
    /// Always positive.
    let cents: Int
}

nonisolated enum LedgerBalanceMath {
    /// Positive means the group owes them. `participants` seeds zeroes.
    static func netCents(
        expenses: [LedgerExpense],
        participants: [String] = []
    ) -> [String: Int] {
        var net = Dictionary(uniqueKeysWithValues: participants.map { ($0, 0) })
        for expense in expenses {
            for share in expense.shares {
                net[share.participantID, default: 0] += share.paidCents - share.owedCents
            }
        }
        return net
    }

    /// The reference implementation `LedgerBalances` is checked against.
    static func netCents(for participantID: String, expenses: [LedgerExpense]) -> Int {
        expenses.reduce(0) { $0 + $1.netCents(for: participantID) }
    }

    /// What `other` owes `me`, one pair at a time. Screens use
    /// `LedgerBalances`, which gets every pair from a single walk.
    static func pairwiseCents(me: String, other: String, expenses: [LedgerExpense]) -> Int {
        expenses.reduce(0) { total, expense in
            guard let mine = expense.share(for: me), let theirs = expense.share(for: other) else { return total }
            return total + pairCents(mine, theirs, totalPaid: expense.totalPaidCents)
        }
    }

    /// What `b` owes `a` for one expense: each debtor's owed amount split
    /// across the payers in proportion to what each fronted. Rounded per
    /// expense so a run of them can't drift, and the only place that happens.
    static func pairCents(_ a: LedgerExpenseShare, _ b: LedgerExpenseShare, totalPaid: Int) -> Int {
        guard totalPaid > 0 else { return 0 }

        func owed(by debtor: LedgerExpenseShare, to creditor: LedgerExpenseShare) -> Double {
            guard debtor.owedCents > 0, creditor.paidCents > 0 else { return 0 }
            let creditorFraction = Double(creditor.paidCents) / Double(totalPaid)
            return Double(debtor.owedCents) * creditorFraction
        }

        return Int((owed(by: b, to: a) - owed(by: a, to: b)).rounded())
    }

    /// Largest debtor against largest creditor, so A owing B owing C becomes
    /// A paying C. Greedy, not provably minimal, but never leaves a balance.
    static func settlements(netCents: [String: Int]) -> [LedgerSettlement] {
        // Id as tiebreaker, or the plan reshuffles between launches.
        func largestFirst(_ lhs: (id: String, cents: Int), _ rhs: (id: String, cents: Int)) -> Bool {
            lhs.cents == rhs.cents ? lhs.id < rhs.id : lhs.cents > rhs.cents
        }
        var creditors = netCents.filter { $0.value > 0 }
            .map { (id: $0.key, cents: $0.value) }
            .sorted(by: largestFirst)
        var debtors = netCents.filter { $0.value < 0 }
            .map { (id: $0.key, cents: -$0.value) }
            .sorted(by: largestFirst)

        var result: [LedgerSettlement] = []
        var creditorIndex = 0
        var debtorIndex = 0
        while creditorIndex < creditors.count, debtorIndex < debtors.count {
            let amount = min(creditors[creditorIndex].cents, debtors[debtorIndex].cents)
            if amount > 0 {
                result.append(LedgerSettlement(
                    from: debtors[debtorIndex].id,
                    to: creditors[creditorIndex].id,
                    cents: amount
                ))
            }
            creditors[creditorIndex].cents -= amount
            debtors[debtorIndex].cents -= amount
            if creditors[creditorIndex].cents == 0 { creditorIndex += 1 }
            if debtors[debtorIndex].cents == 0 { debtorIndex += 1 }
        }
        return result
    }

    /// `payerID` fronts the whole cost. Nil when `allocation` can't describe it.
    static func shares(
        costCents: Int,
        payerID: String,
        participantIDs: [String],
        allocation: SplitAllocation
    ) -> [LedgerExpenseShare]? {
        let others = participantIDs.filter { $0 != payerID }
        guard let owed = allocation.owedCents(totalCents: costCents, participantCount: others.count),
              owed.count == others.count + 1 else { return nil }

        return [LedgerExpenseShare(participantID: payerID, paidCents: costCents, owedCents: owed[0])]
            + zip(others, owed.dropFirst()).map {
                LedgerExpenseShare(participantID: $0, paidCents: 0, owedCents: $1)
            }
    }
}

/// Every figure a ledger's screens draw, from one walk of its expense list.
/// Derived per change, not per view init — a card's `init` runs on every
/// SwiftUI invalidation.
nonisolated struct LedgerBalances: Equatable, Sendable {
    /// Positive means the group owes them; `net(for:)` answers zero for
    /// anyone off every expense.
    let netCents: [String: Int]
    /// `[a][b]` is what b owes a. Pairwise, not net: a net position mixes in
    /// what third parties owe, which says nothing about the pair.
    private let pairwise: [String: [String: Int]]
    /// `pairwise` read off the settlement plan instead, so a debt routed
    /// through someone else collapses. What `simplifiesDebts` shows.
    private let simplifiedPairwise: [String: [String: Int]]
    let settlements: [LedgerSettlement]

    static let empty = LedgerBalances(expenses: [])

    init(expenses: [LedgerExpense]) {
        var net: [String: Int] = [:]
        var pairwise: [String: [String: Int]] = [:]
        for expense in expenses {
            let shares = expense.shares
            let totalPaid = expense.totalPaidCents
            for index in shares.indices {
                let share = shares[index]
                net[share.participantID, default: 0] += share.paidCents - share.owedCents
                // Each unordered pair once: `pairCents` nets both directions,
                // so visiting a pair twice would double it.
                for other in shares[shares.index(after: index)...] {
                    // Only a pair with a payer in it can owe anything.
                    guard share.paidCents > 0 || other.paidCents > 0 else { continue }
                    let cents = LedgerBalanceMath.pairCents(share, other, totalPaid: totalPaid)
                    guard cents != 0 else { continue }
                    pairwise[share.participantID, default: [:]][other.participantID, default: 0] += cents
                    pairwise[other.participantID, default: [:]][share.participantID, default: 0] -= cents
                }
            }
        }
        netCents = net
        self.pairwise = pairwise
        let settlements = LedgerBalanceMath.settlements(netCents: net)
        self.settlements = settlements

        var simplified: [String: [String: Int]] = [:]
        for settlement in settlements {
            simplified[settlement.to, default: [:]][settlement.from, default: 0] += settlement.cents
            simplified[settlement.from, default: [:]][settlement.to, default: 0] -= settlement.cents
        }
        simplifiedPairwise = simplified
    }

    func net(for participantID: String) -> Int { netCents[participantID] ?? 0 }

    /// What `other` owes `me`. The two forms agree on every net position and
    /// can disagree on any single pair — that's the point of the setting.
    func cents(me: String, other: String, simplified: Bool = false) -> Int {
        (simplified ? simplifiedPairwise : pairwise)[me]?[other] ?? 0
    }
}
