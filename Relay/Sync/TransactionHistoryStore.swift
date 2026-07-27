//
//  TransactionHistoryStore.swift
//  Relay
//
//  Newest-first log of the last few successfully created transactions,
//  capped at historyLimit — same lightweight JSON-file pattern as
//  TransactionDraftStore.
//

import Foundation
import os

private nonisolated let logger = Logger(subsystem: Const.loggerSubsystem, category: "TransactionHistoryStore")

nonisolated enum TransactionHistoryStore {
    private static let historyLimit = 10

    private static let fileURL = ApplicationSupportFile.url("transaction-history.json")

    // record() does a load-modify-write that isn't atomic on its own, and
    // callers can record concurrently (e.g. AddYNABTransactionIntent fires
    // its YNAB and Splitwise writes with `async let`). Serialize the whole
    // read/merge/write so a groupId merge always sees the sibling write.
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

    static func load() -> [TransactionHistoryEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        do {
            return try decoder.decode([TransactionHistoryEntry].self, from: data)
        } catch {
            logger.error("failed to decode transaction history, starting empty: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// The id of the newest recorded entry — read right after a successful
    /// write to link that transaction's success notification to its detail
    /// view. Since `record()` inserts (or merges) at the front, this is the
    /// entry the just-finished write produced.
    static func newestEntryID() -> UUID? {
        load().first?.id
    }

    /// Records a created transaction. When `groupId` matches an entry
    /// already recorded from the same wallet automation run, the two are
    /// folded into one combined entry (YNAB transaction + Splitwise split)
    /// instead of adding a second row.
    static func record(summary: String, payload: PendingOperation.Payload, groupId: UUID? = nil, merchant: String? = nil) {
        lock.lock()
        defer { lock.unlock() }

        var entries = load()
        if let groupId,
           let index = entries.firstIndex(where: { $0.groupId == groupId }),
           let merged = entries[index].merging(summary: summary, payload: payload) {
            entries[index] = merged
        } else {
            entries.insert(
                TransactionHistoryEntry(id: UUID(), createdAt: Date(), summary: summary, payload: payload, groupId: groupId, split: nil, merchant: merchant),
                at: 0
            )
        }
        if entries.count > historyLimit {
            entries.removeLast(entries.count - historyLimit)
        }
        do {
            let data = try encoder.encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logger.error("failed to save transaction history: \(String(describing: error), privacy: .public)")
        }
    }

    /// Annotates an existing entry with runs that were recognised as the
    /// same purchase and dropped (see TransactionClaim). Called both when a
    /// duplicate arrives after the original committed, and by the original
    /// itself at commit time to fold in duplicates that arrived while it was
    /// still in flight. A no-op if the entry has since been trimmed away.
    static func recordSuppressions(_ runs: [SuppressedRun], on entryId: UUID) {
        guard !runs.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        var entries = load()
        guard let index = entries.firstIndex(where: { $0.id == entryId }) else {
            logger.error("no history entry \(entryId.uuidString, privacy: .public) to attach suppressions to")
            return
        }
        let known = Set(entries[index].suppressed.map(\.id))
        entries[index].suppressed.append(contentsOf: runs.filter { !known.contains($0.id) })
        do {
            let data = try encoder.encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logger.error("failed to save transaction history: \(String(describing: error), privacy: .public)")
        }
    }
}

private nonisolated extension TransactionHistoryEntry {
    /// Folds a sibling write from the same wallet run into this entry,
    /// keeping the YNAB transaction as the primary `payload` and the
    /// Splitwise expense as `split`. Returns nil when the two can't be
    /// combined (e.g. two writes of the same service share a group), so the
    /// caller records the second one on its own instead.
    func merging(summary newSummary: String, payload newPayload: PendingOperation.Payload) -> TransactionHistoryEntry? {
        switch (payload, newPayload) {
        case (.ynabTransaction, .splitwiseExpense(let expense)):
            var copy = self
            copy.split = Split(summary: newSummary, expense: expense)
            return copy
        case (.splitwiseExpense(let expense), .ynabTransaction):
            // Sibling writes can land out of order under `async let` — if the
            // Splitwise half recorded first, promote the YNAB transaction to
            // the primary payload and keep the earlier expense as the split.
            return TransactionHistoryEntry(
                id: id,
                createdAt: createdAt,
                summary: newSummary,
                payload: newPayload,
                groupId: groupId,
                split: Split(summary: summary, expense: expense),
                merchant: merchant,
                suppressed: suppressed
            )
        default:
            return nil
        }
    }
}

