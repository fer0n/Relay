//
//  CSVStatementParser.swift
//  Relay
//
//  Ports the CSV half of the original "YNAB Toolkit" Shortcut's Pythonista
//  script (~/Downloads/YNAB Toolkit.txt): sniff the delimiter, then split
//  into header + rows. Foundation has no built-in CSV parser, so this is a
//  small quote-aware tokenizer (bank exports quote fields that contain the
//  delimiter, e.g. a payee name with a comma in a comma-delimited file).
//

import Foundation

nonisolated enum CSVStatementParser {
    struct Table {
        let header: [String]
        let rows: [[String]]
    }

    enum CSVParserError: Error {
        case empty
    }

    private static let candidateDelimiters: [Character] = [",", ";", "\t"]

    static func parse(_ data: Data) throws -> Table {
        // Bank exports are frequently Latin-1/Windows-1252, not UTF-8
        // (mirrors the Python original's `encoding="latin-1"`).
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? String(data: data, encoding: .windowsCP1252)
            ?? ""
        guard !text.isEmpty else { throw CSVParserError.empty }

        let delimiter = sniffDelimiter(in: text)
        let rows = tokenize(text, delimiter: delimiter)
            .filter { !($0.count == 1 && $0[0].isEmpty) }
        guard let header = rows.first else { throw CSVParserError.empty }
        return Table(header: header, rows: Array(rows.dropFirst()))
    }

    /// Simplified port of Python's `csv.Sniffer`: picks whichever candidate
    /// delimiter appears the same non-zero number of times across the
    /// first few lines.
    /// Only separators outside quotes count — German exports quote the amount
    /// ("-269,83 €") and the memo, both of which routinely contain a comma.
    private static func sniffDelimiter(in text: String) -> Character {
        var bestDelimiter: Character = ","
        var bestScore = -1
        for delimiter in candidateDelimiters {
            let counts = unquotedDelimiterCountsPerLine(in: text, delimiter: delimiter, limit: 5)
            guard let first = counts.first, first > 0, counts.allSatisfy({ $0 == first }) else { continue }
            if first > bestScore {
                bestScore = first
                bestDelimiter = delimiter
            }
        }
        return bestDelimiter
    }

    /// Counts `delimiter` per record for the first `limit` records, skipping
    /// anything inside quotes — including newlines, so a quoted field spanning
    /// lines stays one record.
    private static func unquotedDelimiterCountsPerLine(in text: String, delimiter: Character, limit: Int) -> [Int] {
        var counts: [Int] = []
        var current = 0
        var inQuotes = false
        var sawContent = false
        for character in text {
            if character == "\"" {
                inQuotes.toggle()
                sawContent = true
                continue
            }
            if inQuotes {
                sawContent = true
                continue
            }
            switch character {
            case delimiter:
                current += 1
                sawContent = true
            case "\n", "\r":
                if sawContent {
                    counts.append(current)
                    if counts.count >= limit { return counts }
                }
                current = 0
                sawContent = false
            default:
                sawContent = true
            }
        }
        if sawContent { counts.append(current) }
        return counts
    }

    /// Char-by-char state machine so quoted fields can contain the
    /// delimiter or embedded newlines.
    private static func tokenize(_ text: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var currentRow: [String] = []
        var currentField = ""
        var inQuotes = false
        var iterator = text.makeIterator()
        var pending = iterator.next()

        func endField() {
            currentRow.append(currentField)
            currentField = ""
        }
        func endRow() {
            endField()
            rows.append(currentRow)
            currentRow = []
        }

        while let char = pending {
            pending = iterator.next()
            if inQuotes {
                if char == "\"" {
                    if pending == "\"" {
                        currentField.append("\"")
                        pending = iterator.next()
                    } else {
                        inQuotes = false
                    }
                } else {
                    currentField.append(char)
                }
                continue
            }
            switch char {
            case "\"":
                inQuotes = true
            case delimiter:
                endField()
            case "\r":
                if pending == "\n" { pending = iterator.next() }
                endRow()
            case "\n":
                endRow()
            default:
                currentField.append(char)
            }
        }
        if !currentField.isEmpty || !currentRow.isEmpty {
            endRow()
        }
        return rows
    }
}
