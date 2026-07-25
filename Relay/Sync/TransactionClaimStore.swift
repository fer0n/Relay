//
//  TransactionClaimStore.swift
//  Relay
//
//  The ledger behind TransactionClaim's dedupe — same lightweight JSON-file
//  pattern as TransactionDraftStore/TransactionHistoryStore.
//
//  Deliberately separate from TransactionHistoryStore: history records only
//  *successes*, is capped for the re-add UI, and is shaped around what a row
//  should display. Dedupe needs the opposite — in-flight runs included,
//  failures explicitly excluded, and retention driven by the match window
//  rather than by how many rows look good on screen.
//
//  Every check the match performs is local (this ledger plus the already
//  loaded WalletTransactionConfig), so a suppressed run costs zero YNAB or
//  Splitwise API calls. That matters: wiring up notification automations
//  roughly doubles the number of runs, against YNAB's 200 requests/hour cap.
//

import Foundation
import os

private let logger = Logger(subsystem: "com.octabits.relay", category: "TransactionClaimStore")

enum TransactionClaimStore {
    /// How far apart two sightings of the same purchase can be. The Wallet
    /// automation fires at tap; the bank push can lag well behind it,
    /// especially if the phone was offline at the till.
    static let matchWindow: TimeInterval = 10 * 60

    /// Claims older than this are dropped on the next write. Only needs to
    /// comfortably exceed `matchWindow` — past that a claim can no longer
    /// match anything, and its suppressions have already been folded into
    /// the history entry.
    private static let retention: TimeInterval = 60 * 60

    /// Backstop against the file growing without bound if pruning by age
    /// somehow doesn't keep up (a clock jumping backwards, say).
    private static let claimLimit = 50

    private static let fileURL = ApplicationSupportFile.url("transaction-claims.json")

    // Same rationale as TransactionHistoryStore's lock: every mutation here
    // is a load-modify-write, and two automations firing at once is the
    // entire scenario this file exists for. Checking for a duplicate and
    // claiming must also be one indivisible step (see `claimOrSuppress`),
    // or two runs can both see "no match" and both write.
    private static let lock = NSLock()

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// What a starting run should do: proceed as normal, or stop because
    /// this purchase has already been seen through another automation.
    enum Outcome {
        /// No duplicate — the run owns this claim id and must eventually
        /// `commit` or `abandon` it.
        case claimed(UUID)
        case suppressed(Suppression)
    }

    struct Suppression {
        /// The run that got there first.
        let matched: TransactionClaim
        /// The record of *this* run, already parked on `matched`.
        let run: SuppressedRun
        /// The history entry to annotate and deep-link the notification to.
        /// Nil when `matched` is still in flight — its suppressions are
        /// parked on the claim and folded in by `commit` instead.
        let historyEntryId: UUID?
    }

    /// Checks for a duplicate and, if there isn't one, claims the run — as a
    /// single locked step so two simultaneous automations can't both decide
    /// they're first.
    static func claimOrSuppress(_ candidate: TransactionClaim.Candidate) -> Outcome {
        lock.lock()
        defer { lock.unlock() }

        var claims = load()

        if let matched = TransactionClaim.firstMatch(in: claims, for: candidate, window: matchWindow) {
            let run = candidate.asSuppressedRun
            if let index = claims.firstIndex(where: { $0.id == matched.id }) {
                claims[index].suppressed.append(run)
                save(claims)
            }
            logger.log("suppressing \(candidate.source, privacy: .public) run — duplicate of \(matched.source, privacy: .public) claim from \(Int(candidate.occurredAt.timeIntervalSince(matched.claimedAt)), privacy: .public)s earlier")
            return .suppressed(Suppression(matched: matched, run: run, historyEntryId: matched.historyEntryId))
        }

        let claim = TransactionClaim(
            id: UUID(),
            source: candidate.source,
            destination: candidate.destination,
            amount: candidate.amount,
            claimedAt: candidate.occurredAt,
            accountId: candidate.accountId,
            merchant: candidate.merchant,
            state: .inFlight,
            historyEntryId: nil
        )
        claims.append(claim)
        save(claims)
        logger.log("claimed \(candidate.source, privacy: .public) run for \(candidate.destination.rawValue, privacy: .public)")
        return .claimed(claim.id)
    }

    /// Marks a run as having actually written its transaction, and returns
    /// any runs suppressed against it while it was still in flight so the
    /// caller can fold them into the history entry it just created.
    @discardableResult
    static func commit(_ id: UUID, historyEntryId: UUID?) -> [SuppressedRun] {
        lock.lock()
        defer { lock.unlock() }

        var claims = load()
        guard let index = claims.firstIndex(where: { $0.id == id }) else { return [] }
        claims[index].state = .committed
        claims[index].historyEntryId = historyEntryId
        let parked = claims[index].suppressed
        save(claims)
        return parked
    }

    /// Marks a run as having ended without writing anything, so it stops
    /// shadowing incoming runs. The second automation is the safety net for
    /// exactly this case and has to be let through.
    static func abandon(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }

        var claims = load()
        guard let index = claims.firstIndex(where: { $0.id == id }) else { return }
        claims[index].state = .abandoned
        save(claims)
    }

    /// Records the account this run resolved its card to, once it's known —
    /// the mapping may not have existed when the claim was written (an
    /// unmapped card is asked about mid-run). Lets a later sighting reject
    /// on a conflicting account instead of matching on amount and time alone.
    static func setAccountId(_ accountId: String, for id: UUID) {
        lock.lock()
        defer { lock.unlock() }

        var claims = load()
        guard let index = claims.firstIndex(where: { $0.id == id }), claims[index].accountId != accountId else { return }
        claims[index].accountId = accountId
        save(claims)
    }

    // MARK: - Persistence

    /// Callers hold `lock`.
    private static func load() -> [TransactionClaim] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        do {
            return try decoder.decode([TransactionClaim].self, from: data)
        } catch {
            // Losing the ledger costs at most one duplicate transaction, so
            // starting empty beats refusing to run the automation.
            logger.error("failed to decode transaction claims, starting empty: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// Callers hold `lock`.
    private static func save(_ claims: [TransactionClaim]) {
        let cutoff = Date().addingTimeInterval(-retention)
        var pruned = claims.filter { $0.claimedAt > cutoff }
        if pruned.count > claimLimit {
            pruned.removeFirst(pruned.count - claimLimit)
        }
        do {
            let data = try encoder.encode(pruned)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logger.error("failed to save transaction claims: \(String(describing: error), privacy: .public)")
        }
    }
}
