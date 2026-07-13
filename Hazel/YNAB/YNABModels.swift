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
}

struct YNABTransactionEnvelope: Codable {
    let transaction: YNABTransactionRequest
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
