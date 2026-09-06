//
//  TransactionService.swift
//  Relay
//
//  The two places Relay writes a transaction to — YNAB, and a shared iCloud
//  ledger. Shared by PendingOperation, TransactionDraft, and
//  TransactionHistoryEntry so their list rows can all use the same
//  TransactionSummaryRow.
//

import Foundation
import SwiftUI

/// Codable purely so `TransactionClaim` can persist its destination —
/// nothing else stores this type (PendingOperation/TransactionDraft/
/// TransactionHistoryEntry all derive `service` from their payload), so the
/// raw values are free to be whatever reads best on disk.
nonisolated enum TransactionService: String, Codable {
    case ynab
    /// A shared iCloud ledger — see `Relay/Ledger/`. Replaced a `splitwise`
    /// case; a claim file still containing that raw value fails to decode,
    /// which SplitwiseRemovalMigration clears rather than leaving to fail on
    /// every launch.
    case ledger

    var displayName: String {
        switch self {
        case .ynab: "YNAB"
        case .ledger: "Ledger"
        }
    }

    var systemImage: String {
        switch self {
        case .ynab: "banknote.fill"
        case .ledger: Const.Symbol.ledger
        }
    }

    /// YNAB's title field is the payee; a split's is a free-text
    /// description — shared by every detail row that shows a transaction's
    /// title (TransactionDetailView's history/pending content).
    var titleFieldLabel: LocalizedStringKey {
        switch self {
        case .ynab: "Payee"
        case .ledger: "Description"
        }
    }

}
