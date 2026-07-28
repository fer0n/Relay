//
//  TransactionDraftLimitTests.swift
//  RelayTests
//
//  Covers TransactionDraftGuard.splitByLimit — the pure split behind the
//  "Max Drafts Kept" setting (see DraftLimitPreferenceStore). The actual
//  file write and notification cancellation it feeds into aren't exercised
//  here, same as TransactionClaimMatchTests leaves TransactionClaimStore's
//  I/O untested.
//

import Foundation
import Testing
@testable import Relay

@MainActor
struct TransactionDraftLimitTests {
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    private static func draft(id: UUID = UUID(), at offset: TimeInterval) -> TransactionDraft {
        TransactionDraft(
            id: id,
            startedAt: base.addingTimeInterval(offset),
            payload: .ynabWallet(merchant: "ACME", amount: 12.34, card: "card-1")
        )
    }

    @Test
    func nothingDroppedWhenUnderLimit() {
        let drafts = [Self.draft(at: 0), Self.draft(at: 60)]
        let result = TransactionDraftGuard.splitByLimit(drafts, limit: 5)
        #expect(result.kept.count == 2)
        #expect(result.dropped.isEmpty)
    }

    @Test
    func nothingDroppedWhenExactlyAtLimit() {
        let drafts = [Self.draft(at: 0), Self.draft(at: 60)]
        let result = TransactionDraftGuard.splitByLimit(drafts, limit: 2)
        #expect(result.kept.count == 2)
        #expect(result.dropped.isEmpty)
    }

    @Test
    func emptyListStaysEmpty() {
        let result = TransactionDraftGuard.splitByLimit([], limit: 5)
        #expect(result.kept.isEmpty)
        #expect(result.dropped.isEmpty)
    }

    /// The oldest drafts are the ones dropped, regardless of their position
    /// in the input array — insertion order doesn't track recency once
    /// `transition(_:to:)` is in play (it keeps a draft's original id and
    /// startedAt rather than re-adding it at the end).
    @Test
    func oldestDraftsAreDroppedFirst() {
        let oldest = Self.draft(at: 0)
        let middle = Self.draft(at: 60)
        let newest = Self.draft(at: 120)
        let result = TransactionDraftGuard.splitByLimit([middle, oldest, newest], limit: 2)
        #expect(result.kept.map(\.id) == [newest.id, middle.id])
        #expect(result.dropped.map(\.id) == [oldest.id])
    }

    /// No need to normalize order for the common case where nothing needs
    /// trimming — sorting only happens once trimming is actually required.
    @Test
    func orderIsLeftUntouchedWhenNothingIsTrimmed() {
        let oldest = Self.draft(at: 0)
        let newest = Self.draft(at: 120)
        let result = TransactionDraftGuard.splitByLimit([oldest, newest], limit: 5)
        #expect(result.kept.map(\.id) == [oldest.id, newest.id])
    }

    @Test
    func droppingToOneKeepsOnlyTheNewest() {
        let oldest = Self.draft(at: 0)
        let newest = Self.draft(at: 120)
        let result = TransactionDraftGuard.splitByLimit([oldest, newest], limit: 1)
        #expect(result.kept.map(\.id) == [newest.id])
        #expect(result.dropped.map(\.id) == [oldest.id])
    }

    @Test
    func zeroLimitDropsEverything() {
        let drafts = [Self.draft(at: 0), Self.draft(at: 60)]
        let result = TransactionDraftGuard.splitByLimit(drafts, limit: 0)
        #expect(result.kept.isEmpty)
        #expect(result.dropped.count == 2)
    }
}
