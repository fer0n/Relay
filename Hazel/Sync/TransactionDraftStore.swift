//
//  TransactionDraftStore.swift
//  Hazel
//

import Foundation
import os

private let logger = Logger(subsystem: "com.pentlandFirth.Hazel", category: "TransactionDraftStore")

enum TransactionDraftStore {
    private static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("transaction-drafts.json")
    }()

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

    static func load() -> [TransactionDraft] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        do {
            return try decoder.decode([TransactionDraft].self, from: data)
        } catch {
            logger.error("failed to decode transaction drafts, starting empty: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    static func save(_ drafts: [TransactionDraft]) throws {
        let data = try encoder.encode(drafts)
        try data.write(to: fileURL, options: .atomic)
    }
}
