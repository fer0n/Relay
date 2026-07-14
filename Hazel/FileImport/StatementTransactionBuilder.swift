//
//  StatementTransactionBuilder.swift
//  Hazel
//
//  Ports get_ynab_transactions/get_import_id_with_occurence from the
//  original "YNAB Toolkit" Shortcut's Pythonista script
//  (~/Downloads/YNAB Toolkit.txt): drops stale (>5y) or zero-amount rows,
//  caps memos at 200 chars, and assigns each transaction a YNAB
//  `import_id` (`YNAB:{amount}:{date}:{occurrence}`) so re-importing an
//  overlapping statement date range is a no-op — YNAB dedupes on
//  `import_id` server-side.
//

import Foundation

nonisolated enum StatementTransactionBuilder {
    struct BuildResult {
        let transactions: [YNABTransactionRequest]
        /// Rows dropped for being outside the 5-year window or zero-amount.
        let skippedCount: Int
    }

    private static let ynabDateFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter
    }()

    static func build(
        from rows: [ImportedStatementRow],
        accountId: String,
        importMemos: Bool,
        today: Date = Date(),
        calendar: Calendar = .current
    ) -> BuildResult {
        guard let fiveYearsAgo = calendar.date(byAdding: .day, value: -365 * 5, to: today) else {
            return BuildResult(transactions: [], skippedCount: rows.count)
        }

        struct Draft {
            let dateString: String
            let milliunits: Int
            let payeeName: String
            let memo: String?
        }

        var drafts: [Draft] = []
        var skipped = 0

        for row in rows {
            guard row.date <= today, row.date >= fiveYearsAgo else {
                skipped += 1
                continue
            }
            let milliunits = Int((row.amount * 1000).rounded())
            guard milliunits != 0 else {
                skipped += 1
                continue
            }
            let memo = importMemos ? row.memo.map { String($0.prefix(200)) } : nil
            drafts.append(Draft(
                dateString: ynabDateFormat.string(from: row.date),
                milliunits: milliunits,
                payeeName: row.payeeName,
                memo: memo
            ))
        }

        // Sort so same-amount/same-date rows land adjacent, then assign an
        // incrementing occurrence suffix within each such group.
        drafts.sort { "\($0.milliunits):\($0.dateString)" < "\($1.milliunits):\($1.dateString)" }

        var transactions: [YNABTransactionRequest] = []
        var previousKey: String?
        var occurrence = 0
        for draft in drafts {
            let key = "\(draft.milliunits):\(draft.dateString)"
            occurrence = (key == previousKey) ? occurrence + 1 : 1
            previousKey = key
            let importId = "YNAB:\(draft.milliunits):\(draft.dateString):\(occurrence)"
            transactions.append(YNABTransactionRequest(
                accountId: accountId,
                date: draft.dateString,
                amount: draft.milliunits,
                payeeName: draft.payeeName,
                memo: draft.memo,
                cleared: "cleared",
                approved: false,
                importId: String(importId.prefix(36))
            ))
        }
        return BuildResult(transactions: transactions, skippedCount: skipped)
    }
}
