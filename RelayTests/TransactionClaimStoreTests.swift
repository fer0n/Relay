//
//  TransactionClaimStoreTests.swift
//  RelayTests
//
//  Steps two wallet-automation runs through TransactionClaimStore's claim and
//  commit transitions one at a time, in the orders they can interleave.
//

import Foundation
import Testing
@testable import Relay

@MainActor
struct TransactionClaimStoreTests {
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    private static func wallet(
        destination: TransactionService = .ynab,
        at offset: TimeInterval = 60,
        canFile: Bool = true
    ) -> TransactionClaim.Candidate {
        TransactionClaim.Candidate(
            source: TransactionClaim.normalizedSource(nil),
            destination: destination,
            amount: 12.34,
            accountId: nil,
            merchant: "ACME",
            occurredAt: base.addingTimeInterval(offset),
            parksDraftOnly: !canFile
        )
    }

    private static func push(
        destination: TransactionService = .ynab,
        at offset: TimeInterval = 0
    ) -> TransactionClaim.Candidate {
        TransactionClaim.Candidate(
            source: "bank notification",
            destination: destination,
            amount: 12.34,
            accountId: nil,
            merchant: "Kartenzahlung ACME GMBH//BERLIN",
            occurredAt: base.addingTimeInterval(offset),
            parksDraftOnly: true
        )
    }

    private static func claimedId(_ outcome: TransactionClaimStore.Outcome) -> UUID? {
        if case .claimed(let id) = outcome { id } else { nil }
    }

    private static func suppression(_ outcome: TransactionClaimStore.Outcome) -> TransactionClaimStore.Suppression? {
        if case .suppressed(let suppression) = outcome { suppression } else { nil }
    }

    // MARK: - Push first, confirmation required

    @Test
    func parkingClaimIsAwaitingConfirmationFromTheStart() throws {
        var claims: [TransactionClaim] = []
        let draftId = UUID()

        let id = try #require(Self.claimedId(TransactionClaimStore.claimOrSuppress(Self.push(), parkingDraft: draftId, in: &claims)))

        let claim = try #require(claims.first { $0.id == id })
        #expect(claim.state == .awaitingConfirmation)
        #expect(claim.draftId == draftId)
    }

    /// The race: a writing run checking in before the parked run has saved its
    /// draft used to find an in-flight claim and be dropped.
    @Test(arguments: [TransactionService.ynab, .ledger])
    func writingRunRightAfterAParkingClaimIsNotSuppressed(destination: TransactionService) {
        var claims: [TransactionClaim] = []
        _ = TransactionClaimStore.claimOrSuppress(Self.push(destination: destination), parkingDraft: UUID(), in: &claims)

        let outcome = TransactionClaimStore.claimOrSuppress(Self.wallet(destination: destination), in: &claims)

        #expect(Self.claimedId(outcome) != nil)
    }

    @Test
    func unfileableWalletRunIsStillSuppressedByAParkingClaim() {
        var claims: [TransactionClaim] = []
        _ = TransactionClaimStore.claimOrSuppress(Self.push(), parkingDraft: UUID(), in: &claims)

        let outcome = TransactionClaimStore.claimOrSuppress(Self.wallet(canFile: false), in: &claims)

        #expect(Self.suppression(outcome) != nil)
        #expect(claims.count == 1)
    }

    @Test(arguments: [TransactionService.ynab, .ledger])
    func writingRunCommitClearsTheParkedDraft(destination: TransactionService) throws {
        var claims: [TransactionClaim] = []
        let draftId = UUID()
        let pushId = try #require(Self.claimedId(TransactionClaimStore.claimOrSuppress(Self.push(destination: destination), parkingDraft: draftId, in: &claims)))
        let walletId = try #require(Self.claimedId(TransactionClaimStore.claimOrSuppress(Self.wallet(destination: destination), in: &claims)))

        let result = try #require(TransactionClaimStore.commit(walletId, historyEntryId: UUID(), in: &claims))

        #expect(result.supersededDraftIds == [draftId])
        #expect(result.suppressed.map(\.source) == ["bank notification"])
        #expect(claims.first { $0.id == pushId }?.state == .abandoned)
        #expect(claims.first { $0.id == walletId }?.state == .committed)
    }

    /// The commit can land before the parked run saves its draft, in which case
    /// clearing `supersededDraftIds` removed nothing and the parked run has to
    /// notice on its own.
    @Test
    func parkedRunLearnsItWasSupersededAfterTheFact() throws {
        var claims: [TransactionClaim] = []
        let pushId = try #require(Self.claimedId(TransactionClaimStore.claimOrSuppress(Self.push(), parkingDraft: UUID(), in: &claims)))
        #expect(!TransactionClaimStore.wasSuperseded(pushId, in: claims))

        let walletId = try #require(Self.claimedId(TransactionClaimStore.claimOrSuppress(Self.wallet(), in: &claims)))
        _ = TransactionClaimStore.commit(walletId, historyEntryId: nil, in: &claims)

        #expect(TransactionClaimStore.wasSuperseded(pushId, in: claims))
    }

    @Test
    func missingClaimIsNotSuperseded() {
        #expect(!TransactionClaimStore.wasSuperseded(UUID(), in: []))
    }

    /// Answering "Add" on the Confirm notification commits the parked claim, so
    /// the Wallet run arriving afterwards must not add the purchase again.
    @Test
    func approvedDraftSuppressesALateWalletRun() throws {
        var claims: [TransactionClaim] = []
        let pushId = try #require(Self.claimedId(TransactionClaimStore.claimOrSuppress(Self.push(), parkingDraft: UUID(), in: &claims)))
        let entryId = UUID()
        _ = TransactionClaimStore.commit(pushId, historyEntryId: entryId, in: &claims)

        let suppression = try #require(Self.suppression(TransactionClaimStore.claimOrSuppress(Self.wallet(), in: &claims)))

        #expect(suppression.matched.id == pushId)
        #expect(suppression.historyEntryId == entryId)
    }

    // MARK: - Wallet first

    @Test(arguments: [TransactionService.ynab, .ledger])
    func pushWhileWalletIsInFlightFoldsIntoTheCommit(destination: TransactionService) throws {
        var claims: [TransactionClaim] = []
        let walletId = try #require(Self.claimedId(TransactionClaimStore.claimOrSuppress(Self.wallet(destination: destination, at: 0), in: &claims)))

        let suppression = try #require(Self.suppression(
            TransactionClaimStore.claimOrSuppress(Self.push(destination: destination, at: 60), parkingDraft: UUID(), in: &claims)
        ))
        #expect(suppression.historyEntryId == nil)
        #expect(claims.count == 1)

        let result = try #require(TransactionClaimStore.commit(walletId, historyEntryId: UUID(), in: &claims))
        #expect(result.suppressed.map(\.source) == ["bank notification"])
        #expect(result.supersededDraftIds.isEmpty)
    }

    @Test
    func pushAfterWalletCommitIsSuppressedOntoItsHistoryEntry() throws {
        var claims: [TransactionClaim] = []
        let walletId = try #require(Self.claimedId(TransactionClaimStore.claimOrSuppress(Self.wallet(at: 0), in: &claims)))
        let entryId = UUID()
        _ = TransactionClaimStore.commit(walletId, historyEntryId: entryId, in: &claims)

        let suppression = try #require(Self.suppression(
            TransactionClaimStore.claimOrSuppress(Self.push(at: 60), parkingDraft: UUID(), in: &claims)
        ))

        #expect(suppression.historyEntryId == entryId)
    }

    @Test
    func commitOfUnknownClaimReportsNothing() {
        var claims: [TransactionClaim] = []
        #expect(TransactionClaimStore.commit(UUID(), historyEntryId: nil, in: &claims) == nil)
    }
}
