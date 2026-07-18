//
//  YNABModels.swift
//  Relay
//
//  Codable models for the subset of the YNAB API (https://api.ynab.com/v1)
//  used to create transactions. JSONDecoder/JSONEncoder use snake_case
//  conversion, so property names here are plain camelCase.
//

import Foundation

struct YNABAccount: Codable {
    let id: String
    let name: String
    let closed: Bool
    let deleted: Bool
}

struct YNABCategory: Codable {
    let id: String
    let name: String
    let hidden: Bool
    let deleted: Bool
}

struct YNABCategoryGroup: Codable {
    let id: String
    let name: String
    let hidden: Bool
    let deleted: Bool
    let categories: [YNABCategory]
}

struct YNABTransactionRequest: Codable {
    let accountId: String
    let date: String
    let amount: Int
    let payeeName: String
    let categoryId: String?
    let memo: String?
    let cleared: String
    let approved: Bool
    /// Only set for file-import transactions (see StatementTransactionBuilder):
    /// lets YNAB dedupe re-imports of an overlapping statement date range
    /// server-side, rather than Relay tracking what's already been sent.
    let importId: String?

    init(
        accountId: String,
        date: String,
        amount: Int,
        payeeName: String,
        categoryId: String? = nil,
        memo: String? = nil,
        cleared: String,
        approved: Bool,
        importId: String? = nil
    ) {
        self.accountId = accountId
        self.date = date
        self.amount = amount
        self.payeeName = payeeName
        self.categoryId = categoryId
        self.memo = memo
        self.cleared = cleared
        self.approved = approved
        self.importId = importId
    }
}

struct YNABTransactionEnvelope: Codable {
    let transaction: YNABTransactionRequest
}

nonisolated struct YNABBulkTransactionEnvelope: Codable {
    let transactions: [YNABTransactionRequest]
}

nonisolated struct YNABCreatedTransaction: Codable {
    let amount: Int
    let payeeName: String?
    let accountName: String?
}

// MARK: - Response envelopes

struct YNABAccountsResponse: Codable {
    struct DataWrapper: Codable { let accounts: [YNABAccount] }
    let data: DataWrapper
}

struct YNABCategoriesResponse: Codable {
    struct DataWrapper: Codable { let categoryGroups: [YNABCategoryGroup] }
    let data: DataWrapper
}

nonisolated struct YNABBulkImportResult: Codable {
    let transactionIds: [String]
    let transactions: [YNABCreatedTransaction]
    let duplicateImportIds: [String]

    /// Mirrors the original "YNAB Toolkit" Shortcut's `handle_response`: the
    /// single transaction's amount/payee if exactly one was created,
    /// otherwise a count. The primary half of the result summary — see
    /// `duplicatesLine` for the rest.
    var summaryLine: String {
        if transactions.count == 1, let transaction = transactions.first {
            let amount = Double(transaction.amount) / 1000
            let formattedAmount = amount.asMoneyString
            if let payeeName = transaction.payeeName, !payeeName.isEmpty {
                return "\(formattedAmount), \(payeeName)"
            }
            return formattedAmount
        } else if transactions.count > 1 {
            return "\(transactions.count) transactions created"
        }
        return "No new transactions created"
    }

    /// YNAB's own `import_id` dedup count, if any — the secondary half of
    /// the result summary, kept separate from `summaryLine` so callers can
    /// render it on its own line instead of crammed into one sentence.
    var duplicatesLine: String? {
        guard !duplicateImportIds.isEmpty else { return nil }
        return "\(duplicateImportIds.count) duplicates found"
    }

    /// `summaryLine` + `duplicatesLine` joined into one string, for
    /// ImportYNABFileIntent's Shortcuts dialog, which has no separate
    /// "info text" concept.
    var summaryText: String {
        [summaryLine, duplicatesLine].compactMap { $0 }.joined(separator: ". ")
    }
}

nonisolated struct YNABBulkImportResponse: Codable {
    let data: YNABBulkImportResult
}
