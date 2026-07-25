//
//  TransactionClaim.swift
//  Relay
//
//  One record per wallet-automation *run*, used to recognise the same
//  real-world purchase arriving twice through two different automations.
//
//  Background: the Wallet "Transaction" automation doesn't always fire —
//  it misses sometimes, and it never fires at all for an online Apple Pay
//  purchase. iOS 27's notification automations cover those, triggered off
//  the bank app's push instead. But every Wallet-triggered transaction
//  *should* also produce a bank notification, so with both automations
//  wired up most purchases arrive twice and one of the two has to be
//  dropped.
//
//  Which one is dropped is simply whichever arrives second — first write
//  wins. The alternative (let the later, better-quality Wallet data patch
//  the transaction the notification already created) is a lot of surface
//  area for a case the user can also fix by editing the transaction.
//
//  A claim is written at the very top of perform(), *before* any follow-up
//  question and before TransactionDraftGuard.begin, because a run can sit
//  suspended on a question for minutes. Matching only against completed
//  transactions would let the second automation fire straight through the
//  middle of a still-running first one.
//

import Foundation

/// A run that was recognised as an already-seen transaction and therefore
/// not written. Kept for display only — these collapse into the matched
/// TransactionHistoryEntry rather than becoming rows of their own.
struct SuppressedRun: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    /// The `source` of the *suppressed* run, i.e. the automation that lost
    /// the race — shown as "also seen from …".
    var source: String
    /// The raw merchant string that run was given. Usually differs from the
    /// winning run's (a bank push says "Kartenzahlung ACME GMBH//BERLIN"
    /// where Wallet says "ACME"), which is exactly why it's worth showing.
    var merchant: String
    var amount: Double
    var occurredAt: Date
}

struct TransactionClaim: Codable, Identifiable, Equatable {
    let id: UUID
    /// Which automation this run came from. Two runs sharing a source are
    /// never treated as duplicates of each other: the same automation
    /// firing twice means the user really did pay twice (two taps at the
    /// same merchant for the same amount is a real thing that happens).
    let source: String
    /// YNAB vs Splitwise. Part of the match key so a YNAB-destined card and
    /// a Splitwise-destined card charged the same amount within the window
    /// don't collapse into each other — a real duplicate pair always shares
    /// a destination, since both automations for a given card are wired to
    /// the same intent.
    let destination: TransactionService
    let amount: Double
    let claimedAt: Date
    /// The resolved YNAB account, when known. Compared rather than the raw
    /// card string, since Wallet's "Visa ••1234" and a bank app's "DKB
    /// Visa" both map through `WalletTransactionConfig.cards` to the same
    /// account id. Nil whenever the card isn't mapped yet — and always nil
    /// on the Splitwise path, which has no card parameter at all — so a nil
    /// on either side carries no signal in `matches` rather than counting
    /// as agreement.
    var accountId: String?
    var merchant: String
    var state: State
    /// Set by `commit` once this run has actually recorded a transaction.
    /// A suppression arriving after that point patches the entry directly;
    /// one arriving while the claim is still `inFlight` is parked in
    /// `suppressed` below and folded in when the entry is finally created.
    var historyEntryId: UUID?
    /// The draft a `.awaitingConfirmation` run left for the user to approve,
    /// so a later run that writes the transaction for real can clear it (see
    /// `supersededConfirmations`). Nil in every other state.
    var draftId: UUID?
    /// Runs suppressed against this one.
    var suppressed: [SuppressedRun] = []

    enum State: String, Codable {
        /// perform() is still running — it may be suspended on a follow-up
        /// question, so this is a live claim and still matchable.
        case inFlight
        case committed
        /// The run deliberately wrote nothing because its automation has
        /// "Require Confirmation" set, and left a draft behind instead. It
        /// doesn't shadow a run that's going to write for real — the whole
        /// point is that nothing has been added yet — but it does shadow
        /// another confirmation-only run, so one purchase can't pile up two
        /// drafts asking the same question.
        case awaitingConfirmation
        /// The run ended without writing anything (an API failure, a
        /// dismissed question, the process killed). No longer matchable:
        /// the second automation is the safety net for exactly this case
        /// and must be allowed through.
        case abandoned
    }

    /// Whether this claim's state lets it shadow `candidate` at all — the
    /// half of the match that's about what each run *did*, as opposed to
    /// `isSamePurchase`, which is about what they're both looking at.
    private func shadows(_ candidate: Candidate) -> Bool {
        switch state {
        case .inFlight, .committed: true
        case .awaitingConfirmation: candidate.requireConfirmation
        case .abandoned: false
        }
    }

    /// Whether `candidate` is the same real-world purchase as this claim,
    /// ignoring what either run did about it.
    ///
    /// Amount must be exactly equal (to the cent) — deliberately strict.
    /// A tolerance band would let two genuinely different purchases in the
    /// same window collapse, and the one case exact matching gives up on
    /// (a foreign-currency charge, where Wallet reports the transaction
    /// currency and the bank push the converted amount) is rare enough to
    /// be worth an occasional duplicate.
    private func isSamePurchase(as candidate: Candidate, window: TimeInterval) -> Bool {
        guard destination == candidate.destination else { return false }
        guard !source.matchesSource(candidate.source) else { return false }
        guard amount.isSameAmount(as: candidate.amount) else { return false }
        guard abs(claimedAt.timeIntervalSince(candidate.occurredAt)) < window else { return false }
        // Only a *conflict* rejects. Either side being nil means the card
        // simply isn't mapped (or there's no card at all), which says
        // nothing either way — amount and time carry the match there.
        if let accountId, let candidateAccountId = candidate.accountId, accountId != candidateAccountId {
            return false
        }
        return true
    }

    /// Whether an incoming run should be dropped in favour of this claim.
    func matches(_ candidate: Candidate, window: TimeInterval) -> Bool {
        shadows(candidate) && isSamePurchase(as: candidate, window: window)
    }

    /// The inputs a starting run is matched on, before it becomes a claim
    /// of its own. Separate from `TransactionClaim` so `matches` can't
    /// accidentally be handed a persisted claim's `state`/`suppressed`
    /// fields as if they were the incoming run's.
    struct Candidate {
        var source: String
        var destination: TransactionService
        var amount: Double
        var accountId: String?
        var merchant: String
        var occurredAt: Date = Date()
        /// This run's "Require Confirmation" setting — it can't write on its
        /// own, so an existing draft awaiting confirmation is already asking
        /// its question for it (see `shadows`).
        var requireConfirmation: Bool = false

        var asSuppressedRun: SuppressedRun {
            SuppressedRun(source: source, merchant: merchant, amount: amount, occurredAt: occurredAt)
        }
    }

    /// How this claim would present itself if it were the incoming run —
    /// lets a claim be matched back against the ledger (see
    /// `supersededConfirmations`).
    var asCandidate: Candidate {
        Candidate(
            source: source,
            destination: destination,
            amount: amount,
            accountId: accountId,
            merchant: merchant,
            occurredAt: claimedAt
        )
    }

    /// This claim as a "also seen from …" record on someone else's history
    /// entry — used when a writing run adopts the drafts of the
    /// confirmation-only sightings it supersedes.
    var asSuppressedRun: SuppressedRun {
        SuppressedRun(source: source, merchant: merchant, amount: amount, occurredAt: claimedAt)
    }
}

extension TransactionClaim {
    /// The claim `candidate` duplicates, or nil if it's a new transaction.
    /// Pure (no store, no clock) so the whole match rule is testable
    /// without touching Application Support.
    ///
    /// Ties are broken by closeness in time rather than by position in the
    /// ledger: with two active claims at the same amount — a genuine
    /// double-charge the user made twice — the incoming run is the second
    /// automation for whichever of them it landed nearest.
    static func firstMatch(
        in claims: [TransactionClaim],
        for candidate: Candidate,
        window: TimeInterval
    ) -> TransactionClaim? {
        claims
            .filter { $0.matches(candidate, window: window) }
            .min { abs($0.claimedAt.timeIntervalSince(candidate.occurredAt)) < abs($1.claimedAt.timeIntervalSince(candidate.occurredAt)) }
    }

    /// The confirmation-only sightings that `claim` — a run that just wrote
    /// the transaction for real — answers on their behalf.
    ///
    /// This is the mirror image of `matches`: an `awaitingConfirmation` claim
    /// deliberately stands aside for a run that can actually write, which
    /// would otherwise leave its draft sitting there asking to add a
    /// transaction that now exists. The writing run adopts them instead —
    /// dropping their drafts and folding them into its history entry, so the
    /// user ends up with the same single collapsed row either way round.
    static func supersededConfirmations(
        in claims: [TransactionClaim],
        by claim: TransactionClaim,
        window: TimeInterval
    ) -> [TransactionClaim] {
        let candidate = claim.asCandidate
        return claims.filter { $0.state == .awaitingConfirmation && $0.isSamePurchase(as: candidate, window: window) }
    }

    /// The source recorded when a shortcut leaves the parameter blank —
    /// which every automation built before the parameter existed does, so
    /// they keep behaving exactly as before.
    static let defaultSource = "wallet"

    /// Normalises a shortcut-supplied source: trimmed, and blank collapsed
    /// to `defaultSource`. Case is preserved for display; comparison is
    /// case-insensitive (see `matchesSource`).
    static func normalizedSource(_ raw: String?) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? defaultSource : trimmed
    }
}

private extension String {
    /// Sources are free text typed into Shortcuts by hand, so "Wallet" and
    /// "wallet" are the same automation as far as dedupe is concerned.
    func matchesSource(_ other: String) -> Bool {
        caseInsensitiveCompare(other) == .orderedSame
    }
}

private extension Double {
    /// Compared in whole cents: these amounts arrive as Shortcuts-supplied
    /// Doubles, where `==` on two values that both display as 12.34 is not
    /// reliable.
    func isSameAmount(as other: Double) -> Bool {
        Int((self * Const.centsPerUnit).rounded()) == Int((other * Const.centsPerUnit).rounded())
    }
}
