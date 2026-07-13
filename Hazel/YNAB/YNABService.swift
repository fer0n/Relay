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

import Foundation

enum YNABAPIError: Error {
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case server(status: Int)
    case noBudget
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

    /// The account has one budget per person sharing it, so the user picks
    /// which one to use rather than the app guessing.
    static func fetchBudgets(token: String) async throws -> [YNABBudgetSummary] {
        let data = try await get("budgets", token: token)
        return try decoder.decode(YNABBudgetsResponse.self, from: data).data.budgets
    }

    static func fetchAccounts(budgetID: String, token: String) async throws -> [YNABAccount] {
        let data = try await get("budgets/\(budgetID)/accounts", token: token)
        return try decoder.decode(YNABAccountsResponse.self, from: data).data.accounts
            .filter { !$0.closed && !$0.deleted }
    }

    static func fetchCategories(budgetID: String, token: String) async throws -> [YNABCategory] {
        let data = try await get("budgets/\(budgetID)/categories", token: token)
        return try decoder.decode(YNABCategoriesResponse.self, from: data).data.categoryGroups
            .filter { !$0.hidden && !$0.deleted }
            .flatMap { $0.categories }
            .filter { !$0.hidden && !$0.deleted }
    }

    static func createTransaction(_ transaction: YNABTransactionRequest, budgetID: String, token: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("budgets/\(budgetID)/transactions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(YNABTransactionEnvelope(transaction: transaction))

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)
    }

    static func todayDateString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter.string(from: Date())
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
