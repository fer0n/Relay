//
//  TransactionClaimMatchTests.swift
//  RelayTests
//
//  Covers TransactionClaim's dedupe rule — the logic that decides whether a
//  wallet-automation run is a purchase already handled by the *other*
//  automation (the Wallet "Transaction" automation vs. an iOS 27 notification
//  automation on the bank app's push), and so should be dropped.
//
//  Both directions of the failure matter and are covered here: matching too
//  eagerly silently loses a real transaction, matching too rarely puts a
//  duplicate in YNAB. The rule is exercised through `matches`/`firstMatch`,
//  which are pure — TransactionClaimStore's file I/O isn't involved.
//

import Foundation
import Testing
@testable import Relay

@MainActor
struct TransactionClaimMatchTests {
    private static let window: TimeInterval = 10 * 60
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    private static func claim(
        source: String = "wallet",
        destination: TransactionService = .ynab,
        amount: Double = 12.34,
        at offset: TimeInterval = 0,
        accountId: String? = "acct-1",
        merchant: String = "ACME",
        state: TransactionClaim.State = .inFlight
    ) -> TransactionClaim {
        TransactionClaim(
            id: UUID(),
            source: source,
            destination: destination,
            amount: amount,
            claimedAt: base.addingTimeInterval(offset),
            accountId: accountId,
            merchant: merchant,
            state: state,
            historyEntryId: nil
        )
    }

    private static func candidate(
        source: String = "bank notification",
        destination: TransactionService = .ynab,
        amount: Double = 12.34,
        at offset: TimeInterval = 0,
        accountId: String? = "acct-1",
        merchant: String = "Kartenzahlung ACME GMBH//BERLIN"
    ) -> TransactionClaim.Candidate {
        TransactionClaim.Candidate(
            source: source,
            destination: destination,
            amount: amount,
            accountId: accountId,
            merchant: merchant,
            occurredAt: base.addingTimeInterval(offset)
        )
    }

    // MARK: - The happy path

    @Test
    func notificationRunMatchesEarlierWalletRun() {
        #expect(Self.claim().matches(Self.candidate(at: 90), window: Self.window))
    }

    /// Order-independent by design: the bank push can beat the Wallet
    /// automation, and often will if Wallet's run is sitting on a question.
    @Test
    func walletRunMatchesEarlierNotificationRun() {
        let earlier = Self.claim(source: "bank notification")
        #expect(earlier.matches(Self.candidate(source: "wallet", at: 90), window: Self.window))
    }

    /// Merchant strings routinely disagree — Wallet says "ACME" where the
    /// bank push says "Kartenzahlung ACME GMBH//BERLIN" — so they're recorded
    /// for display but deliberately play no part in matching.
    @Test
    func merchantTextIsIgnoredWhenMatching() {
        #expect(Self.claim(merchant: "ACME").matches(Self.candidate(merchant: "totally different"), window: Self.window))
    }

    // MARK: - Source

    /// The rule that keeps two genuine taps at the same merchant for the same
    /// amount from collapsing into one: only a *different* automation can be
    /// a duplicate sighting.
    @Test
    func sameSourceNeverMatches() {
        #expect(!Self.claim(source: "wallet").matches(Self.candidate(source: "wallet", at: 60), window: Self.window))
    }

    @Test
    func sourceComparisonIgnoresCase() {
        #expect(!Self.claim(source: "Wallet").matches(Self.candidate(source: "wallet", at: 60), window: Self.window))
    }

    @Test
    func blankSourceNormalizesToWallet() {
        #expect(TransactionClaim.normalizedSource(nil) == "wallet")
        #expect(TransactionClaim.normalizedSource("   ") == "wallet")
        #expect(TransactionClaim.normalizedSource("  bank notification ") == "bank notification")
    }

    // MARK: - Amount

    @Test
    func differingAmountNeverMatches() {
        #expect(!Self.claim(amount: 12.34).matches(Self.candidate(amount: 12.35, at: 60), window: Self.window))
    }

    /// Amounts arrive as Shortcuts-supplied Doubles, so two values that both
    /// display as 12.34 need not be bit-identical — the comparison is in
    /// whole cents.
    @Test
    func amountMatchesDespiteFloatingPointNoise() {
        let noisy = (0.1 + 0.2) + 12.04 // 12.340000000000002
        #expect(Self.claim(amount: 12.34).matches(Self.candidate(amount: noisy, at: 60), window: Self.window))
    }

    // MARK: - Time window

    @Test
    func sightingOutsideWindowDoesNotMatch() {
        #expect(!Self.claim().matches(Self.candidate(at: Self.window + 1), window: Self.window))
    }

    @Test
    func sightingJustInsideWindowMatches() {
        #expect(Self.claim().matches(Self.candidate(at: Self.window - 1), window: Self.window))
    }

    /// The window is symmetric — an earlier candidate is as valid as a later
    /// one, since which automation fires first isn't fixed.
    @Test
    func windowAppliesInBothDirections() {
        #expect(Self.claim().matches(Self.candidate(at: -(Self.window - 1)), window: Self.window))
        #expect(!Self.claim().matches(Self.candidate(at: -(Self.window + 1)), window: Self.window))
    }

    // MARK: - Account

    @Test
    func conflictingAccountsDoNotMatch() {
        #expect(!Self.claim(accountId: "acct-1").matches(Self.candidate(at: 60, accountId: "acct-2"), window: Self.window))
    }

    /// A nil on either side means the card simply isn't mapped yet — or, on
    /// the Splitwise path, that there's no card at all. That's absence of
    /// information, not disagreement, so amount and time carry the match.
    @Test
    func missingAccountOnEitherSideIsNotAConflict() {
        #expect(Self.claim(accountId: nil).matches(Self.candidate(at: 60, accountId: "acct-2"), window: Self.window))
        #expect(Self.claim(accountId: "acct-1").matches(Self.candidate(at: 60, accountId: nil), window: Self.window))
        #expect(Self.claim(accountId: nil).matches(Self.candidate(at: 60, accountId: nil), window: Self.window))
    }

    // MARK: - Destination

    @Test
    func differingDestinationsDoNotMatch() {
        let ynabClaim = Self.claim(destination: .ynab, accountId: nil)
        #expect(!ynabClaim.matches(Self.candidate(destination: .splitwise, at: 60, accountId: nil), window: Self.window))
    }

    // MARK: - State

    /// An in-flight run may be suspended on a follow-up question for minutes.
    /// It still shadows incoming runs — matching only against completed
    /// transactions is exactly the hole this dedupe has to close.
    @Test
    func inFlightClaimStillMatches() {
        #expect(Self.claim(state: .inFlight).matches(Self.candidate(at: 60), window: Self.window))
    }

    @Test
    func committedClaimMatches() {
        #expect(Self.claim(state: .committed).matches(Self.candidate(at: 60), window: Self.window))
    }

    /// An abandoned run wrote nothing, so there's no duplicate to avoid —
    /// and the second automation is precisely the safety net for that case.
    @Test
    func abandonedClaimDoesNotMatch() {
        #expect(!Self.claim(state: .abandoned).matches(Self.candidate(at: 60), window: Self.window))
    }

    // MARK: - Selecting among several claims

    @Test
    func firstMatchReturnsNilWhenNothingMatches() {
        let claims = [Self.claim(source: "wallet", at: -3600), Self.claim(source: "wallet", amount: 99.99)]
        #expect(TransactionClaim.firstMatch(in: claims, for: Self.candidate(at: 60), window: Self.window) == nil)
    }

    /// Two same-amount claims in the window means the user really did pay
    /// twice; the incoming sighting belongs to whichever it landed nearest.
    @Test
    func firstMatchPrefersTheNearestInTime() {
        let far = Self.claim(source: "wallet", at: 0)
        let near = Self.claim(source: "wallet", at: 240)
        let matched = TransactionClaim.firstMatch(in: [far, near], for: Self.candidate(at: 300), window: Self.window)
        #expect(matched?.id == near.id)
    }

    @Test
    func firstMatchSkipsAbandonedInFavorOfAnActiveClaim() {
        let abandoned = Self.claim(source: "wallet", at: 280, state: .abandoned)
        let committed = Self.claim(source: "wallet", at: 0, state: .committed)
        let matched = TransactionClaim.firstMatch(in: [abandoned, committed], for: Self.candidate(at: 300), window: Self.window)
        #expect(matched?.id == committed.id)
    }
}
