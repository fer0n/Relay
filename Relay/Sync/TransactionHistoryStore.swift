//
//  TransactionHistoryStore.swift
//  Relay
//
//  Newest-first log of the last few successfully created transactions.
//

import Foundation
import os

private nonisolated let logger = Logger(subsystem: Const.loggerSubsystem, category: "TransactionHistoryStore")

nonisolated enum TransactionHistoryStore {
    private static let historyLimit = 10

    private static let fileURL = ApplicationSupportFile.url("transaction-history.json")

    // record() is a load-modify-write, and callers record concurrently (the
    // intents fire their YNAB and Splitwise writes with `async let`). Serializing
    // the whole read/merge/write is what lets a groupId merge see its sibling.
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

    /// Read right after a successful write to link its success notification to the
    /// detail view. `record()` inserts (or merges) at the front, so this is the
    /// entry that write produced.
    static func newestEntryID() -> UUID? {
        load().first?.id
    }

    /// A `groupId` matching an already-recorded entry folds the two into one
    /// combined entry rather than adding a second row.
    static func record(summary: String, payload: PendingOperation.Payload, groupId: UUID? = nil, merchant: String? = nil) {
        lock.lock()
        defer { lock.unlock() }

        var entries = load()
        if let groupId,
           let index = entries.firstIndex(where: { $0.groupId == groupId }),
           var merged = entries[index].merging(summary: summary, payload: payload) {
            // Both halves of a wallet run pass the same merchant, so this only
            // fills in an entry whose first-landing half had none to give.
            if merged.merchant == nil {
                merged.merchant = merchant
            }
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

    /// Local-only: the underlying YNAB transaction and Splitwise expense are
    /// untouched, which is why callers must confirm that with the user first.
    static func delete(id: UUID) {
        lock.lock()
        defer { lock.unlock() }

        var entries = load()
        entries.removeAll { $0.id == id }
        do {
            let data = try encoder.encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logger.error("failed to save transaction history: \(String(describing: error), privacy: .public)")
        }
    }

    /// Annotates an entry with runs dropped as duplicates of it (see
    /// TransactionClaim) — called both when a duplicate arrives after the original
    /// committed, and by the original at commit time to fold in ones that arrived
    /// while it was in flight. A no-op if the entry has since been trimmed away.
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
    /// Folds a sibling write into this entry, keeping the YNAB transaction as
    /// `payload` and the Splitwise expense as `split`. Nil when the two can't
    /// combine — two writes of the same service sharing a group — so the caller
    /// records the second on its own.
    func merging(summary newSummary: String, payload newPayload: PendingOperation.Payload) -> TransactionHistoryEntry? {
        switch (payload, newPayload) {
        case (.ynabTransaction, .splitwiseExpense(let expense)):
            var copy = self
            copy.split = Split(summary: newSummary, expense: expense)
            return copy
        case (.splitwiseExpense(let expense), .ynabTransaction):
            // Sibling writes can land out of order under `async let`, so promote
            // the YNAB transaction and demote the earlier expense to the split.
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

