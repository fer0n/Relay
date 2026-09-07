//
//  ImportedRowLedgerMatcher.swift
//  Relay
//
//  Matches parsed statement rows against expenses already on a ledger, however
//  they got there — FileImportHistoryStore only knows rows this device
//  submitted from a file.
//

import Foundation

enum ImportedRowLedgerMatcher {
    static let dayTolerance = 4

    /// Each expense is claimed by at most one row, nearest date first.
    static func likelyExistingIDs(
        rows: [FileImportRow],
        expenses: [LedgerExpense],
        calendar: Calendar = .current
    ) -> Set<String> {
        guard !rows.isEmpty, !expenses.isEmpty else { return [] }

        var byCents: [Int: [(index: Int, day: Date)]] = [:]
        for (index, expense) in expenses.enumerated() where !expense.isSettlement {
            byCents[expense.costCents, default: []].append((index, calendar.startOfDay(for: expense.date)))
        }

        var claimed = Set<Int>()
        var matched = Set<String>()
        for row in rows {
            let cents = SplitShareMath.cents(fromAmount: row.splitAmount)
            guard let candidates = byCents[cents] else { continue }
            let rowDay = calendar.startOfDay(for: row.date)

            let best = candidates
                .filter { !claimed.contains($0.index) }
                .compactMap { candidate -> (index: Int, distance: Int)? in
                    let days = calendar.dateComponents([.day], from: candidate.day, to: rowDay).day ?? 0
                    return abs(days) <= dayTolerance ? (candidate.index, abs(days)) : nil
                }
                .min { $0.distance < $1.distance }
            guard let best else { continue }

            claimed.insert(best.index)
            matched.insert(row.id)
        }
        return matched
    }
}
