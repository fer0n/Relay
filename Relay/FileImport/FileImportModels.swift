//
//  FileImportModels.swift
//  Relay
//
//  The destination-independent model behind SharedFileImportView. Parsing a
//  statement produces one list of [FileImportRow] that both YNAB and Splitwise
//  show and select from identically; the destination only changes the top
//  settings, the submit button, and what happens on submit — never the rows.
//

import Foundation

/// Codable so the active destination survives a dismiss/reopen.
enum FileImportDestination: String, Codable, Hashable {
    case ynab
    case splitwise

    var label: String {
        switch self {
        case .ynab: return "YNAB"
        case .splitwise: return "Splitwise"
        }
    }
}

/// One reviewable transaction parsed from a statement file. The `id` is
/// deterministic across re-imports of the same statement, so it doubles as the
/// SwiftUI identity, the multi-select key, and the dedup key behind
/// FileImportHistoryStore's "already handled" badge.
struct FileImportRow: Codable, Identifiable, Hashable {
    /// "{signedMilliunits}:{yyyy-MM-dd}:{occurrence}" —
    /// StatementTransactionBuilder's YNAB `import_id` encoding minus the "YNAB:"
    /// prefix, so `ynabTransaction(...)` reproduces a byte-identical import_id and
    /// YNAB's own re-import dedup keeps working.
    let id: String
    let date: Date
    let payeeName: String
    let memo: String?
    /// Sign preserved from the statement.
    let amount: Double
}

nonisolated enum FileImportRowBuilder {
    /// Drops zero-amount rows, then gives each remaining one an incrementing
    /// occurrence suffix within its amount+date group. The grouping and sort match
    /// StatementTransactionBuilder so the ids line up with YNAB import_ids — see
    /// `FileImportRow.id`. There's deliberately no staleness filter: the review
    /// screen shows every parsed row rather than dropping any silently.
    static func build(from rows: [ImportedStatementRow]) -> [FileImportRow] {
        struct Draft {
            let dateString: String
            let milliunits: Int
            let row: ImportedStatementRow
        }

        let drafts: [Draft] = rows.compactMap { row in
            let milliunits = Int((row.amount * Const.milliunitsPerUnit).rounded())
            guard milliunits != 0 else { return nil }
            return Draft(dateString: DateFormatter.yyyyMMdd.string(from: row.date), milliunits: milliunits, row: row)
        }.sorted { "\($0.milliunits):\($0.dateString)" < "\($1.milliunits):\($1.dateString)" }

        var result: [FileImportRow] = []
        var previousKey: String?
        var occurrence = 0
        for draft in drafts {
            let key = "\(draft.milliunits):\(draft.dateString)"
            occurrence = (key == previousKey) ? occurrence + 1 : 1
            previousKey = key
            result.append(FileImportRow(
                id: "\(key):\(occurrence)",
                date: draft.row.date,
                payeeName: draft.row.payeeName,
                memo: draft.row.memo,
                amount: draft.row.amount
            ))
        }
        return result
    }
}

extension FileImportRow {
    /// The import_id comes straight from `id`, so it's stable regardless of which
    /// subset of rows is submitted.
    func ynabTransaction(accountId: String, includeMemos: Bool) -> YNABTransactionRequest {
        YNABTransactionRequest(
            accountId: accountId,
            date: DateFormatter.yyyyMMdd.string(from: date),
            amount: Int((amount * Const.milliunitsPerUnit).rounded()),
            payeeName: payeeName,
            memo: includeMemos ? memo.map { String($0.prefix(200)) } : nil,
            cleared: Const.YNAB.cleared,
            approved: false,
            importId: String("YNAB:\(id)".prefix(36))
        )
    }

    /// The statement's sign is irrelevant here — the cost is what gets divided.
    var splitAmount: Double { abs(amount) }
}
