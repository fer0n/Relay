//
//  LedgerExpenseError.swift
//  Relay
//

import Foundation

enum LedgerExpenseError: Error, LocalizedError {
    case validation(String)
    case notAvailable
    case writeFailed(String?)

    var errorDescription: String? {
        switch self {
        case .validation(let message):
            return message
        case .notAvailable:
            return String(localized: "Sign in to iCloud to add to a ledger.")
        case .writeFailed(let message):
            return message ?? String(localized: "Couldn't save to the ledger.")
        }
    }
}
