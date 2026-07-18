//
//  PendingOperationQueueStore.swift
//  Relay
//

import Foundation
import os

private let logger = Logger(subsystem: "com.octabits.relay", category: "PendingOperationQueueStore")

enum PendingOperationQueueStore {
    private static let fileURL = ApplicationSupportFile.url("pending-operations.json")

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

    static func load() -> [PendingOperation] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        do {
            return try decoder.decode([PendingOperation].self, from: data)
        } catch {
            logger.error("failed to decode pending operations, starting empty: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    static func save(_ operations: [PendingOperation]) throws {
        let data = try encoder.encode(operations)
        try data.write(to: fileURL, options: .atomic)
    }
}
