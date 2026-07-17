//
//  SplitwiseImportModels.swift
//  Hazel
//
//  Candidate rows for the Splitwise file-import review screen (see
//  ImportSplitwiseFileIntent/SplitwiseFileImportReviewView) — built from the
//  same [ImportedStatementRow] the YNAB file import uses, but with a
//  Splitwise-specific dedup id instead of YNAB's import_id.
//

import Foundation

struct SplitwiseImportRow: Codable, Identifiable {
    /// "SW:{cents}:{yyyy-MM-dd}:{occurrence}" — deterministic across
    /// re-imports of the same statement (rows sort into the same order),
    /// so SplitwiseImportHistoryStore can flag "already split" on a
    /// re-import of an overlapping date range.
    let id: String
    let date: Date
    let payeeName: String
    let memo: String?
    /// Always positive — the statement's sign is irrelevant once a row is a
    /// candidate to split (the cost either way is what gets divided).
    let amount: Double
}

nonisolated enum SplitwiseImportRowBuilder {
    /// Drops zero-amount rows (nothing to split), then assigns each
    /// remaining row an incrementing occurrence suffix within its
    /// amount+date group — mirrors StatementTransactionBuilder's import_id
    /// idea, but as its own small implementation since the math (cents vs.
    /// milliunits, no 5-year staleness filter) differs enough not to share.
    static func build(from rows: [ImportedStatementRow]) -> [SplitwiseImportRow] {
        struct Draft {
            let dateString: String
            let cents: Int
            let row: ImportedStatementRow
        }

        let drafts: [Draft] = rows.compactMap { row in
            let cents = Int((abs(row.amount) * 100).rounded())
            guard cents != 0 else { return nil }
            return Draft(dateString: DateFormatter.yyyyMMdd.string(from: row.date), cents: cents, row: row)
        }.sorted { "\($0.cents):\($0.dateString)" < "\($1.cents):\($1.dateString)" }

        var result: [SplitwiseImportRow] = []
        var previousKey: String?
        var occurrence = 0
        for draft in drafts {
            let key = "\(draft.cents):\(draft.dateString)"
            occurrence = (key == previousKey) ? occurrence + 1 : 1
            previousKey = key
            result.append(SplitwiseImportRow(
                id: "SW:\(key):\(occurrence)",
                date: draft.row.date,
                payeeName: draft.row.payeeName,
                memo: draft.row.memo,
                amount: abs(draft.row.amount)
            ))
        }
        return result
    }
}
