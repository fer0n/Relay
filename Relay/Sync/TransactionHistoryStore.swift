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

    static func record(summary: String, payload: PendingOperation.Payload) {
        var entries = load()
        entries.insert(TransactionHistoryEntry(id: UUID(), createdAt: Date(), summary: summary, payload: payload), at: 0)
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
