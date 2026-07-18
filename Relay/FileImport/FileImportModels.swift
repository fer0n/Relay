//
//  FileImportModels.swift
//  Relay
//
//  The unified, destination-independent model behind the file-import review
//  screen (SharedFileImportView). Parsing a statement produces one list of
//  [FileImportRow] that both YNAB and Splitwise show and select from
//  identically — the destination only changes the top settings, the submit
//  button, and what happens on submit, never the rows themselves. Replaces
//  the old parallel YNABImportRow/SplitwiseImportRow + per-destination
//  staging stores, which each held their own copy of the rows and could
//  drift apart (switching destinations rebuilt from scratch and could come
//  up empty).
//

import Foundation

/// Where a parsed file gets sent. Codable so the active destination can be
/// remembered on the staged import across a dismiss/reopen.
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

/// One reviewable transaction parsed from a statement file, before any
/// destination-specific shaping. The `id` is deterministic across re-imports
/// of the same statement (rows sort into the same order), so it doubles as
/// the SwiftUI identity, the multi-select key, and the dedup key for
/// FileImportHistoryStore's "already handled" badge.
struct FileImportRow: Codable, Identifiable, Hashable {
    /// "{signedMilliunits}:{yyyy-MM-dd}:{occurrence}" — the same encoding
    /// StatementTransactionBuilder gives a YNAB `import_id` (minus the
    /// "YNAB:" prefix), so `ynabTransaction(...)` can reproduce a byte-
    /// identical import_id and YNAB's server-side re-import dedup keeps
    /// working unchanged.
    let id: String
    let date: Date
    let payeeName: String
    let memo: String?
    /// Sign preserved from the statement — shown as-is in the review list.
    let amount: Double
}

nonisolated enum FileImportRowBuilder {
    /// Drops zero-amount rows (nothing to import or split), then assigns each
    /// remaining row an incrementing occurrence suffix within its
    /// amount+date group. The grouping/sort is identical to
    /// StatementTransactionBuilder so the ids line up with YNAB import_ids —
    /// see FileImportRow.id. Unlike the old builder there is no 5-year
    /// staleness filter: the review screen shows every parsed row and lets
    /// the user deselect what they don't want, rather than dropping rows
    /// silently.
    static func build(from rows: [ImportedStatementRow]) -> [FileImportRow] {
        struct Draft {
            let dateString: String
            let milliunits: Int
            let row: ImportedStatementRow
        }

        let drafts: [Draft] = rows.compactMap { row in
            let milliunits = Int((row.amount * 1000).rounded())
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
    /// Shapes this row into a YNAB create request. The import_id is derived
    /// straight from `id` (which already encodes milliunits/date/occurrence),
    /// so it's stable regardless of which subset of rows is submitted and
    /// matches what StatementTransactionBuilder would have produced.
    func ynabTransaction(accountId: String, includeMemos: Bool) -> YNABTransactionRequest {
        YNABTransactionRequest(
            accountId: accountId,
            date: DateFormatter.yyyyMMdd.string(from: date),
            amount: Int((amount * 1000).rounded()),
            payeeName: payeeName,
            memo: includeMemos ? memo.map { String($0.prefix(200)) } : nil,
            cleared: "cleared",
            approved: false,
            importId: String("YNAB:\(id)".prefix(36))
        )
    }

    /// What Splitwise splits: the statement's sign is irrelevant once a row
    /// is a candidate (the cost either way is what gets divided).
    var splitAmount: Double { abs(amount) }
}
