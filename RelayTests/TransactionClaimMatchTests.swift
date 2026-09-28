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
        state: TransactionClaim.State = .inFlight,
        draftId: UUID? = nil
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
            historyEntryId: nil,
            draftId: draftId
        )
    }

    private static func candidate(
        source: String = "bank notification",
        destination: TransactionService = .ynab,
        amount: Double = 12.34,
        at offset: TimeInterval = 0,
        accountId: String? = "acct-1",
        merchant: String = "Kartenzahlung ACME GMBH//BERLIN",
        parksDraftOnly: Bool = false
    ) -> TransactionClaim.Candidate {
        TransactionClaim.Candidate(
            source: source,
            destination: destination,
            amount: amount,
            accountId: accountId,
            merchant: merchant,
            occurredAt: base.addingTimeInterval(offset),
            parksDraftOnly: parksDraftOnly
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

    /// Blank stays blank rather than becoming "wallet": the invented name used to
    /// collide with a second automation the user had named "Wallet" by hand.
    @Test
    func blankSourceStaysBlank() {
        #expect(TransactionClaim.normalizedSource(nil).isEmpty)
        #expect(TransactionClaim.normalizedSource("   ").isEmpty)
        #expect(TransactionClaim.normalizedSource("  bank notification ") == "bank notification")
    }

    @Test
    func unnamedAutomationIsDisplayedAsWallet() {
        #expect(TransactionClaim.label(for: "") == "Wallet")
        #expect(TransactionClaim.label(for: "bank notification") == "bank notification")
    }

    /// The unnamed automation is a source in its own right, so it still can't be
    /// a duplicate of itself.
    @Test
    func twoUnnamedRunsNeverMatch() {
        #expect(!Self.claim(source: "").matches(Self.candidate(source: "", at: 60), window: Self.window))
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
        #expect(!ynabClaim.matches(Self.candidate(destination: .ledger, at: 60, accountId: nil), window: Self.window))
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

    /// The point of "Require Confirmation": the run parked a draft and added
    /// nothing, so an automation that *can* write has to be let through —
    /// otherwise the purchase would sit unapproved forever while every
    /// subsequent sighting was dropped as a duplicate of it.
    @Test
    func awaitingConfirmationClaimDoesNotShadowAWritingRun() {
        #expect(!Self.claim(state: .awaitingConfirmation).matches(Self.candidate(at: 60), window: Self.window))
    }

    /// But a second sighting that can only park a draft — "Require
    /// Confirmation" set, or a merchant with no template to file it under —
    /// can't write either, so letting it through would only pile a second
    /// draft onto the same purchase.
    @Test
    func awaitingConfirmationClaimShadowsAnotherDraftOnlyRun() {
        let claim = Self.claim(state: .awaitingConfirmation)
        #expect(claim.matches(Self.candidate(at: 60, parksDraftOnly: true), window: Self.window))
    }

    /// The flag only relaxes `awaitingConfirmation`; a run that actually
    /// wrote (or is about to) shadows a draft-only sighting just the same.
    @Test
    func parksDraftOnlyDoesNotChangeMatchingAgainstWritingClaims() {
        let confirming = Self.candidate(at: 60, parksDraftOnly: true)
        #expect(Self.claim(state: .inFlight).matches(confirming, window: Self.window))
        #expect(Self.claim(state: .committed).matches(confirming, window: Self.window))
        #expect(!Self.claim(state: .abandoned).matches(confirming, window: Self.window))
    }

    // MARK: - Superseding a parked confirmation

    @Test
    func committedRunSupersedesAMatchingConfirmationDraft() {
        let parked = Self.claim(source: "bank notification", at: 0, state: .awaitingConfirmation, draftId: UUID())
        let writer = Self.claim(source: "wallet", at: 120, state: .committed)
        let superseded = TransactionClaim.supersededConfirmations(in: [parked, writer], by: writer, window: Self.window)
        #expect(superseded.map(\.id) == [parked.id])
    }

    /// Same guards as the match rule — a parked draft is only answered by a
    /// run looking at the same purchase.
    @Test
    func supersedingRespectsTheSameGuardsAsMatching() {
        let writer = Self.claim(source: "wallet", at: 120, state: .committed)
        let sameSource = Self.claim(source: "wallet", at: 0, state: .awaitingConfirmation)
        let otherAmount = Self.claim(source: "bank notification", amount: 99.99, at: 0, state: .awaitingConfirmation)
        let tooOld = Self.claim(source: "bank notification", at: -(Self.window * 2), state: .awaitingConfirmation)
        let otherAccount = Self.claim(source: "bank notification", at: 0, accountId: "acct-2", state: .awaitingConfirmation)
        let claims = [sameSource, otherAmount, tooOld, otherAccount, writer]
        #expect(TransactionClaim.supersededConfirmations(in: claims, by: writer, window: Self.window).isEmpty)
    }

    /// Only parked confirmations are adopted: an abandoned run's draft is a
    /// genuine safety net for a run that failed, and a committed one has its
    /// own history entry.
    @Test
    func supersedingIgnoresClaimsInEveryOtherState() {
        let writer = Self.claim(source: "wallet", at: 120, state: .committed)
        let claims = [
            Self.claim(source: "bank notification", at: 0, state: .inFlight),
            Self.claim(source: "bank notification", at: 0, state: .committed),
            Self.claim(source: "bank notification", at: 0, state: .abandoned),
            writer,
        ]
        #expect(TransactionClaim.supersededConfirmations(in: claims, by: writer, window: Self.window).isEmpty)
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

    // MARK: - Two automations, one purchase

    @Test(arguments: [TransactionService.ynab, .ledger])
    func walletThenNotificationSuppressesTheSecondRun(destination: TransactionService) {
        let wallet = Self.claim(source: "wallet", destination: destination, at: 0, accountId: nil, state: .committed)
        let push = Self.candidate(source: "notif", destination: destination, at: 90, accountId: nil, parksDraftOnly: true)

        #expect(TransactionClaim.firstMatch(in: [wallet], for: push, window: Self.window)?.id == wallet.id)
    }

    @Test(arguments: [TransactionService.ynab, .ledger])
    func walletStillAskingStillSuppressesTheNotificationRun(destination: TransactionService) {
        let wallet = Self.claim(source: "wallet", destination: destination, at: 0, accountId: nil, state: .inFlight)
        let push = Self.candidate(source: "notif", destination: destination, at: 90, accountId: nil, parksDraftOnly: true)

        #expect(TransactionClaim.firstMatch(in: [wallet], for: push, window: Self.window)?.id == wallet.id)
    }

    @Test(arguments: [TransactionService.ynab, .ledger])
    func notificationThenWalletTakesOverTheConfirmationDraft(destination: TransactionService) {
        let draftId = UUID()
        let parked = Self.claim(
            source: "notif",
            destination: destination,
            at: 0,
            accountId: nil,
            state: .awaitingConfirmation,
            draftId: draftId
        )

        let walletRun = Self.candidate(source: "wallet", destination: destination, at: 90, accountId: nil)
        #expect(TransactionClaim.firstMatch(in: [parked], for: walletRun, window: Self.window) == nil)

        let wallet = Self.claim(source: "wallet", destination: destination, at: 90, accountId: nil, state: .committed)
        let superseded = TransactionClaim.supersededConfirmations(in: [parked, wallet], by: wallet, window: Self.window)
        #expect(superseded.map(\.draftId) == [draftId])
    }

    @Test(arguments: [TransactionService.ynab, .ledger])
    func notificationThenUnfileableWalletRunDoesNotStackASecondDraft(destination: TransactionService) {
        let parked = Self.claim(
            source: "notif",
            destination: destination,
            at: 0,
            accountId: nil,
            state: .awaitingConfirmation,
            draftId: UUID()
        )
        let walletRun = Self.candidate(source: "wallet", destination: destination, at: 90, accountId: nil, parksDraftOnly: true)

        #expect(TransactionClaim.firstMatch(in: [parked], for: walletRun, window: Self.window)?.id == parked.id)
    }

    @Test(arguments: [TransactionService.ynab, .ledger])
    func walletParkedAsDraftThenNotificationIsSuppressed(destination: TransactionService) {
        let parked = Self.claim(
            source: "wallet",
            destination: destination,
            at: 0,
            accountId: nil,
            state: .awaitingConfirmation,
            draftId: UUID()
        )
        let push = Self.candidate(source: "notif", destination: destination, at: 90, accountId: nil, parksDraftOnly: true)

        #expect(parked.matches(push, window: Self.window))
    }

    /// The setup that used to dedupe nothing: the Wallet automation on a blank
    /// Source, the confirm-only one named "Wallet" by hand.
    @Test(arguments: [TransactionService.ynab, .ledger])
    func unnamedWalletRunMergesWithAnAutomationNamedWallet(destination: TransactionService) {
        let wallet = Self.claim(
            source: TransactionClaim.normalizedSource(nil),
            destination: destination,
            at: 0,
            accountId: nil,
            state: .committed
        )
        let push = Self.candidate(source: "Wallet", destination: destination, at: 90, accountId: nil, parksDraftOnly: true)

        #expect(TransactionClaim.firstMatch(in: [wallet], for: push, window: Self.window)?.id == wallet.id)
    }

    /// And the mirror image: the Wallet run arriving second takes over the draft
    /// the hand-named confirm-only run parked.
    @Test(arguments: [TransactionService.ynab, .ledger])
    func walletRunSupersedesAConfirmationDraftNamedWallet(destination: TransactionService) {
        let draftId = UUID()
        let parked = Self.claim(
            source: "Wallet",
            destination: destination,
            at: 0,
            accountId: nil,
            state: .awaitingConfirmation,
            draftId: draftId
        )
        let unnamed = TransactionClaim.normalizedSource(nil)

        let walletRun = Self.candidate(source: unnamed, destination: destination, at: 90, accountId: nil)
        #expect(TransactionClaim.firstMatch(in: [parked], for: walletRun, window: Self.window) == nil)

        let wallet = Self.claim(source: unnamed, destination: destination, at: 90, accountId: nil, state: .committed)
        let superseded = TransactionClaim.supersededConfirmations(in: [parked, wallet], by: wallet, window: Self.window)
        #expect(superseded.map(\.draftId) == [draftId])
    }

    /// What's left of the trap, and all the Source parameter can do about it:
    /// two automations that both decline to name themselves are indistinguishable.
    @Test(arguments: [TransactionService.ynab, .ledger])
    func twoUnnamedAutomationsStillCannotBeToldApart(destination: TransactionService) {
        let unnamed = TransactionClaim.normalizedSource(nil)
        let wallet = Self.claim(source: unnamed, destination: destination, at: 0, accountId: nil, state: .committed)
        let push = Self.candidate(source: unnamed, destination: destination, at: 90, accountId: nil, parksDraftOnly: true)

        #expect(TransactionClaim.firstMatch(in: [wallet], for: push, window: Self.window) == nil)
    }
}
