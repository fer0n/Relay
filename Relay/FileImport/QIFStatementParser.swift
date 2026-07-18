//
//  QIFStatementParser.swift
//  Relay
//
//  Ports the QIF half of the original "YNAB Toolkit" Shortcut's Pythonista
//  script (~/Downloads/YNAB Toolkit.txt, `read_qif_file`): QIF fields are
//  already tagged (D=date, T=amount, P=payee, M=memo), so — unlike CSV —
//  there's no column mapping to ask about, just a date format to detect.
//

import Foundation

struct QIFRawRecord {
    let date: String
    let amount: String
    let payeeName: String?
    let memo: String?
}

struct QIFTable {
    /// The account type from the file's `!Type:<key>` header (e.g. "Bank"),
    /// used as the date-format cache key — mirrors the Python original's
    /// per-type `date_format` lookup.
    let typeKey: String?
    let records: [QIFRawRecord]
}

nonisolated enum QIFStatementParser {
    enum QIFParserError: Error {
        case empty
    }

    static func parse(_ data: Data) throws -> QIFTable {
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? String(data: data, encoding: .windowsCP1252)
            ?? ""
        guard !text.isEmpty else { throw QIFParserError.empty }

        var records: [QIFRawRecord] = []
        var typeKey: String?
        var date: String?
        var amount: String?
        var payeeName: String?
        var memo: String?

        func flushRecord() {
            guard let date, let amount else { return }
            records.append(QIFRawRecord(date: date, amount: amount, payeeName: payeeName, memo: memo))
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : String(rawLine)
            if line.hasPrefix("!Type") {
                // "!Type:Bank" -> "Bank" (6 = "!Type:".count)
                typeKey = String(line.dropFirst(6))
            } else if line.hasPrefix("^") {
                flushRecord()
                date = nil
                amount = nil
                payeeName = nil
                memo = nil
            } else if line.hasPrefix("D") {
                date = String(line.dropFirst())
            } else if line.hasPrefix("T") {
                amount = String(line.dropFirst())
            } else if line.hasPrefix("P") {
                payeeName = String(line.dropFirst())
            } else if line.hasPrefix("M") {
                memo = String(line.dropFirst())
            }
        }

        return QIFTable(typeKey: typeKey, records: records)
    }
}
