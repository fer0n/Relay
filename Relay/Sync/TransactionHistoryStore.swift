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

private let logger = Logger(subsystem: "com.octabits.relay", category: "TransactionHistoryStore")

enum TransactionHistoryStore {
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

    /// Records a created transaction. When `groupId` matches an entry
    /// already recorded from the same wallet automation run, the two are
    /// folded into one combined entry (YNAB transaction + Splitwise split)
    /// instead of adding a second row.
    static func record(summary: String, payload: PendingOperation.Payload, groupId: UUID? = nil) {
        lock.lock()
        defer { lock.unlock() }

        var entries = load()
        if let groupId,
           let index = entries.firstIndex(where: { $0.groupId == groupId }),
           let merged = entries[index].merging(summary: summary, payload: payload) {
            entries[index] = merged
        } else {
            entries.insert(
                TransactionHistoryEntry(id: UUID(), createdAt: Date(), summary: summary, payload: payload, groupId: groupId, split: nil),
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
}

private extension TransactionHistoryEntry {
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
                split: Split(summary: summary, expense: expense)
            )
        default:
            return nil
        }
    }
}

