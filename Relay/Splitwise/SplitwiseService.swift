//
//  SplitwiseService.swift
//  Relay
//
//  Thin client for the documented Splitwise API (https://dev.splitwise.com)
//  used to look up the current user/friends and create an expense. Per
//  Splitwise's API Terms (see CLAUDE.md), the access token is only ever
//  placed in an Authorization header, never logged, and requests are not
//  retried in a tight loop on 429.
//

import Foundation

enum SplitwiseAPIError: Error {
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case server(status: Int)
    case validation(String)
}

nonisolated enum SplitwiseService {
    private static let baseURL = URL(string: "https://secure.splitwise.com/api/v3.0")!

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    static func fetchCurrentUser(token: String) async throws -> SplitwiseUser {
        let data = try await get("get_current_user", token: token)
        return try decoder.decode(SplitwiseCurrentUserResponse.self, from: data).user
    }

    static func fetchFriends(token: String) async throws -> [SplitwiseFriend] {
        let data = try await get("get_friends", token: token)
        return try decoder.decode(SplitwiseFriendsResponse.self, from: data).friends
    }

    static func createExpense(_ expense: SplitwiseExpenseRequest, token: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("create_expense"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: expense.asJSONObject)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)

        // Splitwise returns validation failures (e.g. bad user id) as a 200
        // with a populated "errors" object rather than an HTTP error status.
        let result = try decoder.decode(SplitwiseCreateExpenseResponse.self, from: data)
        let messages = result.errors?.values.flatMap { $0 } ?? []
        if !messages.isEmpty {
            throw SplitwiseAPIError.validation(messages.joined(separator: " "))
        }
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
            throw SplitwiseAPIError.unauthorized
        case 429:
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw SplitwiseAPIError.rateLimited(retryAfter: retryAfter)
        default:
            throw SplitwiseAPIError.server(status: http.statusCode)
        }
    }
}
