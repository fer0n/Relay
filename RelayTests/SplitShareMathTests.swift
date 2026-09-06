//
//  SplitShareMathTests.swift
//  RelayTests
//
//  Whole-cent arithmetic. Nothing server-side checks that shares total the
//  cost, so a cent lost to rounding here becomes a balance that can never be
//  settled — the ledger just says someone owes 0,01 € forever.
//

import Foundation
import Testing
@testable import Relay

struct SplitShareMathTests {
    // MARK: - Distribution

    /// The invariant the whole ledger rests on, across every awkward split
    /// there is.
    @Test(arguments: [1, 2, 3, 5, 7, 100, 999, 1001, 12_345])
    func everyDistributionTotalsExactly(totalCents: Int) {
        for count in 1...7 {
            let even = SplitShareMath.distribute(
                totalCents: totalCents,
                ratios: SplitShareMath.evenRatios(count: count)
            )
            #expect(even.reduce(0, +) == totalCents, "even split of \(totalCents) across \(count)")

            let lopsided = SplitShareMath.distribute(
                totalCents: totalCents,
                ratios: SplitShareMath.ratios(of: (1...count).map { Double($0) })
            )
            #expect(lopsided.reduce(0, +) == totalCents, "weighted split of \(totalCents) across \(count)")
        }
    }

    /// A cent that won't divide lands on the biggest share, so the smallest
    /// one isn't the one visibly nudged.
    @Test func theRoundingRemainderLandsOnTheLargestShare() {
        let parts = SplitShareMath.distribute(totalCents: 100, ratios: SplitShareMath.ratios(of: [1, 1, 1]))
        #expect(parts.reduce(0, +) == 100)
        #expect(parts.max() == 34)
        #expect(parts.sorted() == [33, 33, 34])

        let lopsided = SplitShareMath.distribute(totalCents: 1000, ratios: SplitShareMath.ratios(of: [9, 1, 1]))
        #expect(lopsided.reduce(0, +) == 1000)
        #expect(lopsided[0] == lopsided.max())
    }

    @Test func nobodyToSplitAcrossDistributesNothing() {
        #expect(SplitShareMath.distribute(totalCents: 100, ratios: []).isEmpty)
        #expect(SplitShareMath.evenRatios(count: 0).isEmpty)
        #expect(SplitShareMath.ratios(of: []).isEmpty)
    }

    /// Zero cost still has to produce one share each, or the expense comes
    /// out with fewer participants than it was built for.
    @Test func aZeroCostStillGivesEveryoneAShare() {
        let parts = SplitShareMath.distribute(totalCents: 0, ratios: SplitShareMath.evenRatios(count: 3))
        #expect(parts == [0, 0, 0])
    }

    // MARK: - Ratios

    @Test func evenRatiosAddUpToOne() {
        for count in 1...10 {
            let sum = SplitShareMath.evenRatios(count: count).reduce(0, +)
            #expect(abs(sum - 1) < 1e-9)
        }
    }

    @Test func ratiosAreEachValuesFractionOfTheSum() {
        let ratios = SplitShareMath.ratios(of: [1, 3])
        #expect(abs(ratios[0] - 0.25) < 1e-9)
        #expect(abs(ratios[1] - 0.75) < 1e-9)
    }

    /// All-zero weights mean "no preference", not "nobody owes anything" —
    /// dividing by their sum would be a NaN in every share.
    @Test func weightsThatSumToZeroSplitEvenly() {
        #expect(SplitShareMath.ratios(of: [0, 0, 0]) == SplitShareMath.evenRatios(count: 3))
        #expect(SplitShareMath.distribute(
            totalCents: 300,
            ratios: SplitShareMath.ratios(of: [0, 0, 0])
        ) == [100, 100, 100])
    }

    // MARK: - Parsing

    /// Both decimal separators, since the field is typed into on a German
    /// keyboard as often as an English one.
    @Test func eitherDecimalSeparatorParses() {
        #expect(SplitShareMath.cents("12.34") == 1234)
        #expect(SplitShareMath.cents("12,34") == 1234)
        #expect(SplitShareMath.cents(" 12,34 ") == 1234)
        #expect(SplitShareMath.cents("0") == 0)
    }

    /// A share can be zero, never below it: a negative one would make an
    /// expense that doesn't total its cost.
    @Test func anythingThatIsntANonNegativeAmountIsRejected() {
        #expect(SplitShareMath.cents("-1") == nil)
        #expect(SplitShareMath.cents("-0.01") == nil)
        #expect(SplitShareMath.cents("") == nil)
        #expect(SplitShareMath.cents("   ") == nil)
        #expect(SplitShareMath.cents("abc") == nil)
        #expect(SplitShareMath.cents("1.2.3.4") == nil)
    }

    /// What the amount field shows after an untouched expense is reopened,
    /// so it has to come back the same figure it went in as.
    @Test func centsAndTextAreInverses() {
        for cents in [0, 1, 99, 100, 1234, 100_000] {
            #expect(SplitShareMath.cents(SplitShareMath.text(fromCents: cents)) == cents, "\(cents)")
        }
    }

    @Test func anAmountConvertsTheSameWayTypedTextDoes() {
        #expect(SplitShareMath.cents(fromAmount: 12.34) == 1234)
        #expect(SplitShareMath.cents(fromAmount: 0.1 + 0.2) == 30)
        #expect(SplitShareMath.cents(fromAmount: 12.345) == 1235)
    }
}
