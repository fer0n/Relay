//
//  SplitwiseSplitAllocationTests.swift
//  RelayTests
//
//  Splitwise only accepts an expense whose owed shares add up to its cost
//  exactly, so every way of describing a split — even, a typed own share,
//  relative weights — has to land on whole cents that still total. These cover
//  that for splits with more than one other person, which is what the
//  participant picker can now produce.
//

import Foundation
import Testing
@testable import Relay

struct SplitwiseSplitAllocationTests {
    @Test
    func evenSplitCoversEveryoneIncludingThePayer() {
        let owed = SplitwiseSplitAllocation.equal.owedCents(totalCents: 3000, participantCount: 2)
        #expect(owed == [1000, 1000, 1000])
    }

    @Test
    func evenSplitPutsTheRoundingRemainderSomewhereRatherThanLosingIt() {
        let owed = SplitwiseSplitAllocation.equal.owedCents(totalCents: 1000, participantCount: 2)
        #expect(owed?.reduce(0, +) == 1000)
        // Three ways to split 10.00 evenly is 3.33 each with a cent left over.
        #expect(owed?.sorted() == [333, 333, 334])
    }

    @Test
    func ownShareSpreadsTheRestEvenlyAcrossTheOthers() {
        let owed = SplitwiseSplitAllocation.ownShare(cents: 1000).owedCents(totalCents: 4000, participantCount: 3)
        #expect(owed == [1000, 1000, 1000, 1000])
    }

    @Test
    func ownShareOfTheWholeCostLeavesTheOthersOwingNothing() {
        let owed = SplitwiseSplitAllocation.ownShare(cents: 2500).owedCents(totalCents: 2500, participantCount: 2)
        #expect(owed == [2500, 0, 0])
    }

    @Test
    func ownShareOutsideTheTotalIsRejectedRatherThanClamped() {
        #expect(SplitwiseSplitAllocation.ownShare(cents: 3000).owedCents(totalCents: 2500, participantCount: 1) == nil)
        #expect(SplitwiseSplitAllocation.ownShare(cents: -1).owedCents(totalCents: 2500, participantCount: 1) == nil)
    }

    @Test
    func weightsDivideInTheirGivenRatio() {
        let owed = SplitwiseSplitAllocation.weights([2, 1, 1]).owedCents(totalCents: 4000, participantCount: 2)
        #expect(owed == [2000, 1000, 1000])
    }

    @Test
    func aZeroWeightBillsThatPersonNothing() {
        let owed = SplitwiseSplitAllocation.weights([0, 1, 1]).owedCents(totalCents: 3000, participantCount: 2)
        #expect(owed == [0, 1500, 1500])
    }

    @Test
    func weightsThatDontLineUpWithTheParticipantsAreRejected() {
        // One weight short of "you plus two others".
        #expect(SplitwiseSplitAllocation.weights([1, 1]).owedCents(totalCents: 3000, participantCount: 2) == nil)
        // Nothing to split by.
        #expect(SplitwiseSplitAllocation.weights([0, 0]).owedCents(totalCents: 3000, participantCount: 1) == nil)
    }

    @Test
    func nobodyToSplitWithIsNotASplit() {
        #expect(SplitwiseSplitAllocation.equal.owedCents(totalCents: 3000, participantCount: 0) == nil)
    }

    @Test
    func everyAllocationTotalsTheCostExactly() {
        for total in [1, 999, 1000, 1234, 100_001] {
            for count in 1...5 {
                #expect(SplitwiseSplitAllocation.equal.owedCents(totalCents: total, participantCount: count)?.reduce(0, +) == total)
                let weights = [Double](repeating: 1, count: count) + [3]
                #expect(SplitwiseSplitAllocation.weights(weights).owedCents(totalCents: total, participantCount: count)?.reduce(0, +) == total)
                #expect(SplitwiseSplitAllocation.ownShare(cents: total / 3).owedCents(totalCents: total, participantCount: count)?.reduce(0, +) == total)
            }
        }
    }
}
