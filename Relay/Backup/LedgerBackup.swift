//
//  LedgerBackup.swift
//  Relay
//

import CloudKit
import CryptoKit
import Foundation

nonisolated struct LedgerBackupCheck: Codable, Equatable, Sendable {
    let expenseCount: Int
    let totalCents: Int
    let netCentsByParticipant: [String: Int]
    let digest: String

    init(expenses: [LedgerExpense], participantIDs: [String]) {
        expenseCount = expenses.count
        totalCents = expenses.reduce(0) { $0 + $1.costCents }
        netCentsByParticipant = LedgerBalanceMath.netCents(
            expenses: expenses,
            participants: participantIDs
        )
        digest = LedgerBackupCheck.digest(of: expenses)
    }

    static func digest(of expenses: [LedgerExpense]) -> String {
        let lines = expenses
            .map { expense in
                let shares = expense.shares
                    .sorted { $0.participantID < $1.participantID }
                    .map { "\($0.participantID):\($0.paidCents):\($0.owedCents)" }
                    .joined(separator: ",")
                return [
                    expense.id,
                    expense.title,
                    String(expense.costCents),
                    expense.currencyCode,
                    String(expense.date.timeIntervalSince1970.rounded()),
                    expense.isSettlement ? "1" : "0",
                    expense.createdBy ?? "",
                    shares,
                ].joined(separator: "|")
            }
            .sorted()
            .joined(separator: "\n")
        let hash = SHA256.hash(data: Data(lines.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated struct LedgerBackup: Codable, Sendable {
    struct Participant: Codable, Sendable {
        let id: String
        let name: String?
        let isOwner: Bool
        let hasAccepted: Bool

        init(_ participant: LedgerParticipant) {
            id = participant.id
            name = participant.name
            isOwner = participant.isOwner
            hasAccepted = participant.hasAccepted
        }
    }

    struct StoredLedger: Codable, Sendable {
        let zoneName: String
        let zoneOwnerName: String
        let name: String
        let currencyCode: String
        let createdAt: Date
        let isOwnedByCurrentUser: Bool
        let simplifiesDebts: Bool
        let participants: [Participant]
        var expenses: [LedgerExpense]
        let check: LedgerBackupCheck

        init(_ ledger: Ledger, expenses: [LedgerExpense]) {
            zoneName = ledger.zoneID.zoneName
            zoneOwnerName = ledger.zoneID.ownerName
            name = ledger.name
            currencyCode = ledger.currencyCode
            createdAt = ledger.createdAt
            isOwnedByCurrentUser = ledger.isOwnedByCurrentUser
            simplifiesDebts = ledger.simplifiesDebts
            participants = ledger.participants.map(Participant.init)
            let sorted = expenses.sorted { $0.date > $1.date }
            self.expenses = sorted
            check = LedgerBackupCheck(
                expenses: sorted,
                participantIDs: ledger.participants.map(\.id)
            )
        }
    }

    var capturedAt: Date
    var currentUserID: String?
    var ledgers: [StoredLedger]

    init(ledgers: [Ledger], expenses: [String: [LedgerExpense]], currentUserID: String?, capturedAt: Date = Date()) {
        self.capturedAt = capturedAt
        self.currentUserID = currentUserID
        self.ledgers = ledgers
            .sorted { $0.zoneName < $1.zoneName }
            .map { StoredLedger($0, expenses: expenses[$0.zoneName] ?? []) }
    }

    var expenseCount: Int { ledgers.reduce(0) { $0 + $1.expenses.count } }

    var isEmpty: Bool { ledgers.isEmpty }
}
