//
//  YNABModels.swift
//  Hazel
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
    /// server-side, rather than Hazel tracking what's already been sent.
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
}

nonisolated struct YNABBulkImportResponse: Codable {
    let data: YNABBulkImportResult
}
