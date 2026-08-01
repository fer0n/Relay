//
//  TransactionClaim.swift
//  Relay
//
//  One record per wallet-automation *run*, used to recognise the same
//  real-world purchase arriving twice through two different automations.
//
//  The Wallet "Transaction" automation misses sometimes, and never fires for an
//  online Apple Pay purchase; a notification automation on the bank app's push
//  covers those. With both wired up most purchases arrive twice, and whichever
//  arrives second is dropped — first write wins. (Letting the later,
//  better-quality Wallet data patch the existing transaction is a lot of
//  surface area for something the user can fix by editing it.)
//
//  A claim is written at the very top of perform(), before any follow-up
//  question and before TransactionDraftGuard.begin, because a run can sit
//  suspended on a question for minutes — matching only completed transactions
//  would let the second automation fire through the middle of the first.
//

import Foundation

/// A run recognised as an already-seen transaction and therefore not written.
/// Display only — these collapse into the matched TransactionHistoryEntry
/// rather than becoming rows of their own.
nonisolated struct SuppressedRun: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    /// The automation that lost the race — shown as "also seen from …".
    var source: String
    /// Usually differs from the winning run's (a bank push says "Kartenzahlung
    /// ACME GMBH//BERLIN" where Wallet says "ACME"), which is why it's shown.
    var merchant: String
    var amount: Double
    var occurredAt: Date
}

nonisolated struct TransactionClaim: Codable, Identifiable, Equatable {
    let id: UUID
    /// Two runs sharing a source are never duplicates of each other: the same
    /// automation firing twice means the user really did pay twice.
    let source: String
    /// Part of the match key, so a YNAB-destined and a Splitwise-destined card
    /// charged the same amount in the same window don't collapse. A real
    /// duplicate pair always shares a destination.
    let destination: TransactionService
    let amount: Double
    let claimedAt: Date
    /// Compared instead of the raw card string, since Wallet's "Visa ••1234" and
    /// a bank app's "DKB Visa" map to the same account id. Nil when the card
    /// isn't mapped, and always nil on the Splitwise path — so `matches` reads a
    /// nil as no signal rather than as agreement.
    var accountId: String?
    var merchant: String
    var state: State
    /// Set by `commit`. A suppression arriving after that patches the entry
    /// directly; one arriving while still `inFlight` parks in `suppressed` and
    /// is folded in when the entry is created.
    var historyEntryId: UUID?
    /// The draft an `.awaitingConfirmation` run left behind, so a later run that
    /// writes for real can clear it (see `supersededConfirmations`).
    var draftId: UUID?
    var suppressed: [SuppressedRun] = []

    enum State: String, Codable {
        /// perform() may be suspended on a follow-up question, so this is a live
        /// claim and still matchable.
        case inFlight
        case committed
        /// The run deliberately wrote nothing and left a draft instead. It never
        /// shadows a run that's going to write for real, but does shadow another
        /// draft-only run, so one purchase can't pile up two drafts.
        case awaitingConfirmation
        /// The run ended without writing anything. No longer matchable: the
        /// second automation is the safety net for exactly this case.
        case abandoned
    }

    /// The half of the match about what each run *did*, as opposed to
    /// `isSamePurchase`, which is about what they're both looking at.
    private func shadows(_ candidate: Candidate) -> Bool {
        switch state {
        case .inFlight, .committed: true
        case .awaitingConfirmation: candidate.parksDraftOnly
        case .abandoned: false
        }
    }

    /// Whether `candidate` is the same real-world purchase, ignoring what either
    /// run did about it.
    ///
    /// The amount must match to the cent. A tolerance band would collapse two
    /// genuinely different purchases in the same window, and the case exact
    /// matching gives up on — a foreign-currency charge, where Wallet reports
    /// the transaction currency and the bank push the converted amount — is rare
    /// enough to be worth an occasional duplicate.
    private func isSamePurchase(as candidate: Candidate, window: TimeInterval) -> Bool {
        guard destination == candidate.destination else { return false }
        guard !source.matchesSource(candidate.source) else { return false }
        guard amount.isSameAmount(as: candidate.amount) else { return false }
        guard abs(claimedAt.timeIntervalSince(candidate.occurredAt)) < window else { return false }
        // Only a conflict rejects — a nil on either side says nothing, so amount
        // and time carry the match there.
        if let accountId, let candidateAccountId = candidate.accountId, accountId != candidateAccountId {
            return false
        }
        return true
    }

    /// Whether an incoming run should be dropped in favour of this claim.
    func matches(_ candidate: Candidate, window: TimeInterval) -> Bool {
        shadows(candidate) && isSamePurchase(as: candidate, window: window)
    }

    /// The inputs a starting run is matched on, before it becomes a claim of its
    /// own. Separate from `TransactionClaim` so `matches` can't be handed a
    /// persisted claim's `state`/`suppressed` as if they were the incoming run's.
    struct Candidate {
        var source: String
        var destination: TransactionService
        var amount: Double
        var accountId: String?
        var merchant: String
        var occurredAt: Date = Date()
        /// Whether this run can only park a draft rather than add the transaction
        /// itself, in which case a draft already waiting for the same purchase is
        /// asking its question for it — see `shadows`.
        var parksDraftOnly: Bool = false

        var asSuppressedRun: SuppressedRun {
            SuppressedRun(source: source, merchant: merchant, amount: amount, occurredAt: occurredAt)
        }
    }

    /// Lets a claim be matched back against the ledger — see
    /// `supersededConfirmations`.
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

    var asSuppressedRun: SuppressedRun {
        SuppressedRun(source: source, merchant: merchant, amount: amount, occurredAt: claimedAt)
    }
}

nonisolated extension TransactionClaim {
    /// The claim `candidate` duplicates, or nil if it's new. Pure (no store, no
    /// clock) so the match rule is testable without Application Support.
    ///
    /// Ties break on closeness in time, not ledger position: with two active
    /// claims at the same amount — a genuine double-charge — the incoming run
    /// belongs to whichever it landed nearest.
    static func firstMatch(
        in claims: [TransactionClaim],
        for candidate: Candidate,
        window: TimeInterval
    ) -> TransactionClaim? {
        claims
            .filter { $0.matches(candidate, window: window) }
            .min { abs($0.claimedAt.timeIntervalSince(candidate.occurredAt)) < abs($1.claimedAt.timeIntervalSince(candidate.occurredAt)) }
    }

    /// The mirror image of `matches`: an `awaitingConfirmation` claim stands
    /// aside for a run that can actually write, which would otherwise leave its
    /// draft asking to add a transaction that now exists. The writing run adopts
    /// them instead, so the user ends up with one collapsed row either way round.
    static func supersededConfirmations(
        in claims: [TransactionClaim],
        by claim: TransactionClaim,
        window: TimeInterval
    ) -> [TransactionClaim] {
        let candidate = claim.asCandidate
        return claims.filter { $0.state == .awaitingConfirmation && $0.isSamePurchase(as: candidate, window: window) }
    }

    /// Recorded when a shortcut leaves the parameter blank, as every automation
    /// built before it existed does.
    static let defaultSource = "wallet"

    /// Case is preserved for display; comparison is case-insensitive.
    static func normalizedSource(_ raw: String?) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? defaultSource : trimmed
    }
}

private nonisolated extension String {
    /// Sources are typed into Shortcuts by hand, so "Wallet" and "wallet" are
    /// the same automation as far as dedupe is concerned.
    func matchesSource(_ other: String) -> Bool {
        caseInsensitiveCompare(other) == .orderedSame
    }
}

private nonisolated extension Double {
    /// Compared in whole cents: these arrive as Shortcuts-supplied Doubles,
    /// where `==` on two values that both display as 12.34 isn't reliable.
    func isSameAmount(as other: Double) -> Bool {
        Int((self * Const.centsPerUnit).rounded()) == Int((other * Const.centsPerUnit).rounded())
    }
}
