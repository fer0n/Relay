//
//  TransactionService.swift
//  Relay
//
//  The two external services Relay writes transactions to — shared by
//  PendingOperation, TransactionDraft, and TransactionHistoryEntry so their
//  list rows can all use the same TransactionSummaryRow.
//

import Foundation
import SwiftUI

enum TransactionService {
    case ynab
    case splitwise

    var displayName: String {
        switch self {
        case .ynab: "YNAB"
        case .splitwise: "Splitwise"
        }
    }

    var systemImage: String {
        switch self {
        case .ynab: "banknote.fill"
        case .splitwise: "person.2.fill"
        }
    }

    /// YNAB's title field is the payee; Splitwise's is a free-text
    /// description — shared by every detail row that shows a transaction's
    /// title (TransactionDetailView's history/pending content).
    var titleFieldLabel: LocalizedStringKey {
        switch self {
        case .ynab: "Payee"
        case .splitwise: "Description"
        }
    }
}
