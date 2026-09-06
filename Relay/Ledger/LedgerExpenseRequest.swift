//
//  LedgerExpenseRequest.swift
//  Relay
//
//  A ledger write for the history and the pending queue. Carries the *names*
//  of the ledger and its people: history outlives what it describes.
//

import Foundation

nonisolated struct LedgerExpenseRequest: Codable, Equatable {
    let zoneName: String
    let ledgerName: String
    let expenseID: String
    let title: String
    let costCents: Int
    let currencyCode: String
    let shares: [LedgerExpenseShare]
    /// A missing entry leaves that person unnamed rather than misnamed.
    let participantNames: [String: String]
    let date: Date
    /// Optional so a payload queued before this field existed still decodes;
    /// nil is the `false` an expense defaults to.
    var isSettlement: Bool?

    init(
        zoneName: String,
        ledgerName: String,
        expenseID: String,
        title: String,
        costCents: Int,
        currencyCode: String,
        shares: [LedgerExpenseShare],
        participantNames: [String: String],
        date: Date,
        isSettlement: Bool = false
    ) {
        self.zoneName = zoneName
        self.ledgerName = ledgerName
        self.expenseID = expenseID
        self.title = title
        self.costCents = costCents
        self.currencyCode = currencyCode
        self.shares = shares
        self.participantNames = participantNames
        self.date = date
        self.isSettlement = isSettlement
    }

    init(expense: LedgerExpense, ledger: Ledger) {
        self.init(
            zoneName: ledger.zoneName,
            ledgerName: ledger.name,
            expenseID: expense.id,
            title: expense.title,
            costCents: expense.costCents,
            currencyCode: expense.currencyCode,
            shares: expense.shares,
            participantNames: Dictionary(
                ledger.participants.map { ($0.id, $0.displayName) },
                // A malformed share shouldn't trap.
                uniquingKeysWith: { first, _ in first }
            ),
            date: expense.date,
            isSettlement: expense.isSettlement
        )
    }

    /// By amount, not position, so any version's payload reads correctly.
    var payer: LedgerExpenseShare? {
        shares.first { $0.paidCents > 0 } ?? shares.first
    }

    var others: [LedgerExpenseShare] {
        let payerID = payer?.participantID
        return shares.filter { $0.participantID != payerID }
    }

    /// "Alex: 12.00 €", for the history and queue rows.
    var participantsShareSummary: String? {
        let parts = others.compactMap { share -> String? in
            guard let name = participantNames[share.participantID] else { return nil }
            return "\(name): \(share.owedCents.asMoney(currencyCode))"
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// Renames a frozen history entry to match an edited Payee mapping.
    func withTitle(_ newTitle: String) -> LedgerExpenseRequest {
        LedgerExpenseRequest(
            zoneName: zoneName,
            ledgerName: ledgerName,
            expenseID: expenseID,
            title: newTitle,
            costCents: costCents,
            currencyCode: currencyCode,
            shares: shares,
            participantNames: participantNames,
            date: date,
            isSettlement: isSettlement ?? false
        )
    }

    var asExpense: LedgerExpense {
        LedgerExpense(
            id: expenseID,
            title: title,
            costCents: costCents,
            currencyCode: currencyCode,
            date: date,
            shares: shares,
            isSettlement: isSettlement ?? false
        )
    }
}
