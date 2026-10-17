//
//  FileImportPreferences.swift
//  Relay
//
//  Settings a fresh file import starts from: the last "Include Memos" choice,
//  and which YNAB account a statement went to the last time one from the same
//  bank account was imported. Several bank accounts often export through the
//  same app with identical headers, so a statement is recognised by the IBAN
//  every row shares (stored hashed), falling back to its header.
//

import CryptoKit
import Foundation

nonisolated enum FileImportPreferences {
    private static let includeMemosKey = "fileImportIncludeMemos"
    private static let accountsBySourceKey = "fileImportAccountsBySource"

    static var includeMemos: Bool {
        get { UserDefaults.standard.object(forKey: includeMemosKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: includeMemosKey) }
    }

    static func accountId(forSource sourceKey: String?) -> String? {
        guard let sourceKey else { return nil }
        return accountsBySource[sourceKey]
    }

    static func record(accountId: String, forSource sourceKey: String?) {
        guard let sourceKey else { return }
        var map = accountsBySource
        map[sourceKey] = accountId
        UserDefaults.standard.set(map, forKey: accountsBySourceKey)
    }

    private static var accountsBySource: [String: String] {
        UserDefaults.standard.dictionary(forKey: accountsBySourceKey) as? [String: String] ?? [:]
    }

    static func sourceKey(for file: some StatementFileSource) -> String? {
        guard StatementFileResolver.detectKind(for: file) == .csv,
              let table = try? CSVStatementParser.parse(file.data),
              !table.rows.isEmpty
        else { return nil }

        let ibans = sharedIBANs(in: table)
        let identity: String
        switch ibans.count {
        case 0: identity = "header:" + FileImportConfig.csvKey(for: table.header)
        case 1: identity = "iban:" + ibans[0]
        default: return nil
        }
        let digest = SHA256.hash(data: Data(identity.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func sharedIBANs(in table: CSVStatementParser.Table) -> [String] {
        var result: Set<String> = []
        for column in table.header.indices {
            let values = Set(table.rows.map { row in
                column < row.count ? normalizedIBAN(row[column]) : nil
            })
            if values.count == 1, let value = values.first, let value {
                result.insert(value)
            }
        }
        return result.sorted()
    }

    private static func normalizedIBAN(_ raw: String) -> String? {
        let compact = raw.replacingOccurrences(of: " ", with: "").uppercased()
        return compact.wholeMatch(of: /[A-Z]{2}[0-9]{2}[A-Z0-9]{11,30}/) != nil ? compact : nil
    }
}
