//
//  FileImportConfigStore.swift
//  Relay
//
//  Caches the CSV column mapping and detected date format per distinct
//  header, and the detected date format per QIF account type, so a second
//  import from the same bank/export doesn't re-ask the same questions.
//  Mirrors WalletTransactionConfigStore.swift's persistence pattern.
//

import Foundation
import os

private let logger = Logger(subsystem: "com.octabits.relay", category: "FileImportConfigStore")

nonisolated struct FileImportConfig: Codable {
    nonisolated struct HeaderMapping: Codable {
        var dateColumn: Int
        var payeeColumn: Int
        var memoColumn: Int
        var amountColumn: Int
        var dateFormat: String
    }

    var csvMappings: [String: HeaderMapping] = [:]
    var qifDateFormats: [String: String] = [:]

    static func csvKey(for header: [String]) -> String {
        header.joined(separator: "\u{1}")
    }
}

nonisolated enum FileImportConfigStore {
    private static let fileURL = ApplicationSupportFile.url("file-import-config.json")

    static func load() -> FileImportConfig {
        guard let data = try? Data(contentsOf: fileURL) else {
            return FileImportConfig()
        }
        do {
            return try JSONDecoder().decode(FileImportConfig.self, from: data)
        } catch {
            logger.error("failed to decode config, starting empty: \(String(describing: error), privacy: .public)")
            return FileImportConfig()
        }
    }

    static func save(_ config: FileImportConfig) throws {
        let data = try JSONEncoder().encode(config)
        try data.write(to: fileURL, options: .atomic)
        logger.log("saved file import config: \(config.csvMappings.count, privacy: .public) csv mappings, \(config.qifDateFormats.count, privacy: .public) qif date formats")
    }
}
