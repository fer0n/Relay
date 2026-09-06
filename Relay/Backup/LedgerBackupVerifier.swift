//
//  LedgerBackupVerifier.swift
//  Relay
//

import Foundation

nonisolated enum LedgerBackupProblem: Equatable, Sendable {
    case digestMismatch(zoneName: String)
    case expenseCountMismatch(zoneName: String, recorded: Int, actual: Int)
    case totalMismatch(zoneName: String, recorded: Int, actual: Int)
    case netMismatch(zoneName: String, participantID: String, recorded: Int, actual: Int)
    case unbalancedExpense(zoneName: String, expenseID: String)
    case missingLedger(zoneName: String)
    case missingExpenses(zoneName: String, expenseIDs: [String])

    var zoneName: String {
        switch self {
        case .digestMismatch(let zoneName),
             .expenseCountMismatch(let zoneName, _, _),
             .totalMismatch(let zoneName, _, _),
             .netMismatch(let zoneName, _, _, _),
             .unbalancedExpense(let zoneName, _),
             .missingLedger(let zoneName),
             .missingExpenses(let zoneName, _):
            return zoneName
        }
    }

    var message: String {
        switch self {
        case .digestMismatch(let zoneName):
            return "\(zoneName): expense checksum doesn't match the recorded one"
        case .expenseCountMismatch(let zoneName, let recorded, let actual):
            return "\(zoneName): recorded \(recorded) expenses, found \(actual)"
        case .totalMismatch(let zoneName, let recorded, let actual):
            return "\(zoneName): recorded total \(recorded)¢, found \(actual)¢"
        case .netMismatch(let zoneName, let participantID, let recorded, let actual):
            return "\(zoneName): recorded \(recorded)¢ for \(participantID), found \(actual)¢"
        case .unbalancedExpense(let zoneName, let expenseID):
            return "\(zoneName): expense \(expenseID) doesn't balance"
        case .missingLedger(let zoneName):
            return "\(zoneName): in the backup but not in the live data"
        case .missingExpenses(let zoneName, let expenseIDs):
            return "\(zoneName): \(expenseIDs.count) backed-up expense(s) missing from the live data"
        }
    }
}

nonisolated struct LedgerBackupVerification: Equatable, Sendable {
    var ledgerCount: Int
    var expenseCount: Int
    var problems: [LedgerBackupProblem]

    var isValid: Bool { problems.isEmpty }

    var summary: String {
        guard isValid else {
            return "\(problems.count) problem(s): " + problems.map(\.message).joined(separator: "; ")
        }
        return "\(ledgerCount) ledger(s), \(expenseCount) expense(s) verified."
    }
}

nonisolated enum LedgerBackupVerifier {
    static func verify(_ backup: LedgerBackup) -> LedgerBackupVerification {
        var problems: [LedgerBackupProblem] = []

        for ledger in backup.ledgers {
            let recomputed = LedgerBackupCheck(
                expenses: ledger.expenses,
                participantIDs: ledger.participants.map(\.id)
            )
            if recomputed.digest != ledger.check.digest {
                problems.append(.digestMismatch(zoneName: ledger.zoneName))
            }
            if recomputed.expenseCount != ledger.check.expenseCount {
                problems.append(.expenseCountMismatch(
                    zoneName: ledger.zoneName,
                    recorded: ledger.check.expenseCount,
                    actual: recomputed.expenseCount
                ))
            }
            if recomputed.totalCents != ledger.check.totalCents {
                problems.append(.totalMismatch(
                    zoneName: ledger.zoneName,
                    recorded: ledger.check.totalCents,
                    actual: recomputed.totalCents
                ))
            }
            for participantID in Set(recomputed.netCentsByParticipant.keys)
                .union(ledger.check.netCentsByParticipant.keys)
                .sorted() {
                let recorded = ledger.check.netCentsByParticipant[participantID] ?? 0
                let actual = recomputed.netCentsByParticipant[participantID] ?? 0
                if recorded != actual {
                    problems.append(.netMismatch(
                        zoneName: ledger.zoneName,
                        participantID: participantID,
                        recorded: recorded,
                        actual: actual
                    ))
                }
            }
            for expense in ledger.expenses where !expense.isBalanced {
                problems.append(.unbalancedExpense(zoneName: ledger.zoneName, expenseID: expense.id))
            }
        }

        return LedgerBackupVerification(
            ledgerCount: backup.ledgers.count,
            expenseCount: backup.expenseCount,
            problems: problems
        )
    }

    static func crossReference(_ backup: LedgerBackup, with live: LedgerBackup) -> LedgerBackupVerification {
        var problems = verify(backup).problems
        let liveByZone = Dictionary(live.ledgers.map { ($0.zoneName, $0) }, uniquingKeysWith: { first, _ in first })

        for ledger in backup.ledgers {
            guard let counterpart = liveByZone[ledger.zoneName] else {
                problems.append(.missingLedger(zoneName: ledger.zoneName))
                continue
            }
            let backedUpIDs = Set(ledger.expenses.map(\.id))
            let overlap = counterpart.expenses.filter { backedUpIDs.contains($0.id) }
            let missing = backedUpIDs.subtracting(overlap.map(\.id)).sorted()
            if !missing.isEmpty {
                problems.append(.missingExpenses(zoneName: ledger.zoneName, expenseIDs: missing))
            }
            let overlapIDs = Set(overlap.map(\.id))
            let backedUpOverlap = ledger.expenses.filter { overlapIDs.contains($0.id) }
            if LedgerBackupCheck.digest(of: overlap) != LedgerBackupCheck.digest(of: backedUpOverlap) {
                problems.append(.digestMismatch(zoneName: ledger.zoneName))
            }
        }

        return LedgerBackupVerification(
            ledgerCount: backup.ledgers.count,
            expenseCount: backup.expenseCount,
            problems: problems
        )
    }
}
