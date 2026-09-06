//
//  LedgerBalanceMath.swift
//  Relay
//
//  CloudKit stores records and nothing else, so a ledger derives its balances
//  from the expense list: each person's net position, and a short list of
//  "A pays B" transfers that clears everyone at once.
//
//  Free of CloudKit and of the views, so both are testable on their own.
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
    /// Positive means the group owes them. Seeded with `participants` so
    /// someone on no expense still shows up at zero.
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

    /// What one person is owed (positive) or owes (negative) overall.
    static func netCents(for participantID: String, expenses: [LedgerExpense]) -> Int {
        expenses.reduce(0) { $0 + $1.netCents(for: participantID) }
    }

    /// What `other` owes `me`, negative the other way. Per expense rather
    /// than from the net positions, which mix in what third parties owe.
    ///
    /// One pair at a time: a screen wanting every pair should build a
    /// `LedgerBalances`, which gets them all from a single walk.
    static func pairwiseCents(me: String, other: String, expenses: [LedgerExpense]) -> Int {
        expenses.reduce(0) { total, expense in
            guard let mine = expense.share(for: me), let theirs = expense.share(for: other) else { return total }
            return total + pairCents(mine, theirs, totalPaid: expense.totalPaidCents)
        }
    }

    /// What `b` owes `a` for one expense, negative the other way: each
    /// debtor's owed amount split across the payers in proportion to what
    /// each fronted — the only attribution that survives multiple payers,
    /// and the obvious answer when there's one.
    ///
    /// Rounded per expense, so a run of them can't drift a cent at a time.
    /// The single place that rule lives; every pairwise figure comes through
    /// here.
    static func pairCents(_ a: LedgerExpenseShare, _ b: LedgerExpenseShare, totalPaid: Int) -> Int {
        guard totalPaid > 0 else { return 0 }

        func owed(by debtor: LedgerExpenseShare, to creditor: LedgerExpenseShare) -> Double {
            guard debtor.owedCents > 0, creditor.paidCents > 0 else { return 0 }
            let creditorFraction = Double(creditor.paidCents) / Double(totalPaid)
            return Double(debtor.owedCents) * creditorFraction
        }

        return Int((owed(by: b, to: a) - owed(by: a, to: b)).rounded())
    }

    /// Matches the largest debtor against the largest creditor, so where A
    /// owes B and B owes C, A pays C directly. Greedy isn't provably minimal
    /// (that's NP-hard) but never leaves a balance unsettled.
    static func settlements(netCents: [String: Int]) -> [LedgerSettlement] {
        // Id as tiebreaker, or Dictionary's ordering would reshuffle the
        // plan between launches.
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

    /// `payerID` fronts the whole cost; `allocation` decides who owes what.
    /// Nil when the allocation can't describe the split.
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
///
/// Derived once per change to that list rather than per view init: the
/// balance card used to re-derive inside `init`, so every SwiftUI
/// invalidation — a refresh landing, a "Last refreshed" tick — walked every
/// expense once per member of the ledger, on every card on screen.
nonisolated struct LedgerBalances: Equatable, Sendable {
    /// Positive means the group owes them. Only people who appear on an
    /// expense; `net(for:)` answers zero for anyone who doesn't.
    let netCents: [String: Int]
    /// `[a][b]` is what b owes a, negative the other way. Pairwise, not net:
    /// a net position mixes in what third parties owe them, which says
    /// nothing about the pair.
    private let pairwise: [String: [String: Int]]
    /// The same shape as `pairwise`, but read off the settlement plan: a
    /// debt that routes through someone else has been collapsed, so where A
    /// owes B and B owes C, A simply owes C. What a ledger with
    /// `simplifiesDebts` on shows.
    private let simplifiedPairwise: [String: [String: Int]]
    /// Precomputed with the rest — the settle-up plan is read from a body.
    let settlements: [LedgerSettlement]

    /// What a zone with nothing fetched for it yet draws.
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
                // Each unordered pair once: the two directions net against
                // each other inside `pairCents`, so visiting a pair twice
                // would double it.
                for other in shares[shares.index(after: index)...] {
                    // Only a pair with a payer in it can owe anything, which
                    // keeps the usual one-payer expense linear in its shares.
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

    /// What they're owed (positive) or owe (negative) across the ledger.
    func net(for participantID: String) -> Int { netCents[participantID] ?? 0 }

    /// What `other` owes `me`, negative the other way. `simplified` reads
    /// the figure off the settlement plan instead — the two agree on
    /// everyone's net position and can disagree on any single pair, which is
    /// the whole point of the setting.
    func cents(me: String, other: String, simplified: Bool = false) -> Int {
        (simplified ? simplifiedPairwise : pairwise)[me]?[other] ?? 0
    }
}
