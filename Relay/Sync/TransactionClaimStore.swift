//
//  TransactionClaimStore.swift
//  Relay
//
//  The ledger behind TransactionClaim's dedupe.
//
//  Deliberately separate from TransactionHistoryStore, which records only
//  successes, is capped for the re-add UI, and is shaped around what a row
//  should display. Dedupe needs the opposite: in-flight runs included, failures
//  excluded, and retention driven by the match window.
//
//  Every check is local, so a suppressed run costs zero API calls — which
//  matters against YNAB's 200 requests/hour, since a second automation roughly
//  doubles the number of runs.
//

import Foundation
import os

private nonisolated let logger = Logger(subsystem: Const.loggerSubsystem, category: "TransactionClaimStore")

nonisolated enum TransactionClaimStore {
    /// How far apart two sightings of the same purchase can be. The Wallet
    /// automation fires at tap; the bank push can lag well behind.
    static let matchWindow: TimeInterval = 10 * 60

    /// Only needs to comfortably exceed `matchWindow` — past that a claim can no
    /// longer match, and its suppressions are already on the history entry.
    private static let retention: TimeInterval = 60 * 60

    /// Backstop for when pruning by age doesn't keep up — a clock jumping
    /// backwards, say.
    private static let claimLimit = 50

    private static let fileURL = ApplicationSupportFile.url("transaction-claims.json")

    // Every mutation here is a load-modify-write, and two automations firing at
    // once is the entire scenario this file exists for. Checking for a duplicate
    // and claiming must also be indivisible (see `claimOrSuppress`), or two runs
    // can both see "no match" and both write.
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

enum Outcome {
        /// The run owns this claim id and must eventually `commit` or `abandon` it.
        case claimed(UUID)
        case suppressed(Suppression)
    }

    struct Suppression {
        /// The run that got there first.
        let matched: TransactionClaim
        /// The record of *this* run, already parked on `matched`.
        let run: SuppressedRun
        /// Nil while `matched` is still in flight — its suppressions park on the
        /// claim and are folded in by `commit` instead.
        let historyEntryId: UUID?
    }

    /// A single locked step, so two simultaneous automations can't both decide
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

    /// What a committing run has to clean up after itself — see `commit`.
struct CommitResult {
        /// Runs to record as "also seen from …" on the new history entry.
        var suppressed: [SuppressedRun] = []
        /// Drafts left by superseded sightings — the transaction they were asking
        /// about now exists, so the caller clears them.
        var supersededDraftIds: [UUID] = []
    }

    /// Reports what the write invalidates elsewhere in the ledger.
    @discardableResult
    static func commit(_ id: UUID, historyEntryId: UUID?) -> CommitResult {
        lock.lock()
        defer { lock.unlock() }

        var claims = load()
        guard let index = claims.firstIndex(where: { $0.id == id }) else { return CommitResult() }
        claims[index].state = .committed
        claims[index].historyEntryId = historyEntryId

        var result = CommitResult(suppressed: claims[index].suppressed)

        // Confirmation-only runs stood aside for this one, so their drafts now ask
        // to add a transaction that exists. Retired to `.abandoned` so a second
        // commit in the same window can't adopt them twice.
        for superseded in TransactionClaim.supersededConfirmations(in: claims, by: claims[index], window: matchWindow) {
            guard let supersededIndex = claims.firstIndex(where: { $0.id == superseded.id }) else { continue }
            claims[supersededIndex].state = .abandoned
            result.suppressed.append(superseded.asSuppressedRun)
            if let draftId = superseded.draftId {
                result.supersededDraftIds.append(draftId)
            }
            logger.log("superseded awaiting-confirmation \(superseded.source, privacy: .public) run")
        }

        save(claims)
        return result
    }

    /// Marks a run that deliberately wrote nothing, recording the draft it left
    /// behind so a later real write can clear it.
    static func awaitConfirmation(_ id: UUID, draftId: UUID?) {
        lock.lock()
        defer { lock.unlock() }

        var claims = load()
        guard let index = claims.firstIndex(where: { $0.id == id }) else { return }
        claims[index].state = .awaitingConfirmation
        claims[index].draftId = draftId
        save(claims)
    }

    /// Lets approving a draft count as its claim finally writing, so the other
    /// automation arriving late in the window is suppressed rather than adding the
    /// transaction a second time.
    static func claimId(forDraft draftId: UUID) -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        return load().first { $0.draftId == draftId }?.id
    }

    /// Stops a run that wrote nothing from shadowing incoming ones — the second
    /// automation is the safety net for exactly this case.
    static func abandon(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }

        var claims = load()
        guard let index = claims.firstIndex(where: { $0.id == id }) else { return }
        claims[index].state = .abandoned
        save(claims)
    }

    /// Backfills the account, since an unmapped card is asked about mid-run and so
    /// may not have been resolved when the claim was written. Lets a later
    /// sighting reject on a conflicting account rather than matching on amount
    /// and time alone.
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
            // Losing the ledger costs at most one duplicate, so starting empty
            // beats refusing to run the automation.
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
