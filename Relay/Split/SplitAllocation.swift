//
//  SplitAllocation.swift
//  Relay
//

import Foundation

/// How `costCents` divides across the payer and everyone they split with.
nonisolated enum SplitAllocation: Equatable {
    /// An even split across the payer and every participant.
    case equal
    /// The payer owes exactly this; the rest spreads evenly across the others.
    case ownShare(cents: Int)
    /// Relative weights — the payer's first, then one per participant in order.
    case weights([Double])

    /// `[payer, participants…]`, totalling `totalCents` exactly. Nil when the
    /// inputs can't describe a split.
    func owedCents(totalCents: Int, participantCount: Int) -> [Int]? {
        guard participantCount > 0, totalCents >= 0 else { return nil }
        switch self {
        case .equal:
            return SplitShareMath.distribute(
                totalCents: totalCents,
                ratios: SplitShareMath.evenRatios(count: participantCount + 1)
            )
        case .ownShare(let cents):
            guard (0...totalCents).contains(cents) else { return nil }
            let rest = SplitShareMath.distribute(
                totalCents: totalCents - cents,
                ratios: SplitShareMath.evenRatios(count: participantCount)
            )
            return [cents] + rest
        case .weights(let weights):
            guard weights.count == participantCount + 1,
                  weights.allSatisfy({ $0 >= 0 }),
                  weights.reduce(0, +) > 0 else { return nil }
            return SplitShareMath.distribute(
                totalCents: totalCents,
                ratios: SplitShareMath.ratios(of: weights)
            )
        }
    }
}
