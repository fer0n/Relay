//
//  YNABService.swift
//  Hazel
//
//  Thin client for the documented YNAB API (https://api.ynab.com/v1) used to
//  create transactions. Per the YNAB API Terms of Service (see CLAUDE.md):
//  the access token is only ever placed in an Authorization header, never
//  logged, and requests are not retried in a tight loop on 429 — a single
//  rate-limit error is surfaced to the caller instead.
//
//  Uses /plans/default/... rather than picking a budget/plan client-side:
//  this Hazel OAuth app has "default plan selection" enabled, so each user
//  chooses their own plan once during YNAB authorization (see
//  https://api.ynab.com/#oauth-default-plan) and "default" then always
//  resolves to that plan for their token — important since the underlying
//  YNAB account is shared by multiple people, each with their own plan.
//  (/budgets/{budget_id} still works but is undocumented per YNAB's
//  changelog, so it's not used here — see CLAUDE.md's "no undocumented
//  endpoints" constraint.)
//

import Foundation

enum YNABAPIError: Error {
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case server(status: Int)
}

nonisolated enum YNABService {
    private static let baseURL = URL(string: "https://api.ynab.com/v1")!

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }

    static func fetchAccounts(token: String) async throws -> [YNABAccount] {
        let data = try await get("plans/default/accounts", token: token)
        return try decoder.decode(YNABAccountsResponse.self, from: data).data.accounts
            .filter { !$0.closed && !$0.deleted }
    }

    static func fetchCategories(token: String) async throws -> [YNABCategory] {
        let data = try await get("plans/default/categories", token: token)
        return try decoder.decode(YNABCategoriesResponse.self, from: data).data.categoryGroups
            .filter { !$0.hidden && !$0.deleted }
            .flatMap { $0.categories }
            .filter { !$0.hidden && !$0.deleted }
    }

    static func createTransaction(_ transaction: YNABTransactionRequest, token: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("plans/default/transactions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(YNABTransactionEnvelope(transaction: transaction))

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)
    }

    /// Creates many transactions in a single request (same documented
    /// endpoint as `createTransaction`, just with a `transactions` array
    /// body) — used for file import so a whole statement only costs one
    /// call against the 200-req/hour rate limit, regardless of size.
    static func createTransactions(_ transactions: [YNABTransactionRequest], token: String) async throws -> YNABBulkImportResult {
        var request = URLRequest(url: baseURL.appendingPathComponent("plans/default/transactions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(YNABBulkTransactionEnvelope(transactions: transactions))

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)
        return try decoder.decode(YNABBulkImportResponse.self, from: data).data
    }

    static func todayDateString() -> String {
        DateFormatter.yyyyMMdd.string(from: Date())
    }

    private static func get(_ path: String, token: String) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)
        return data
    }

    private static func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200...299:
            return
        case 401:
            throw YNABAPIError.unauthorized
        case 429:
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw YNABAPIError.rateLimited(retryAfter: retryAfter)
        default:
            throw YNABAPIError.server(status: http.statusCode)
        }
    }
}
