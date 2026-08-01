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
        // Only `get_expenses` responses carry a Date field (`date`); Splitwise
        // documents it as e.g. "2012-07-27T05:00:00Z" but also emits
        // fractional-second timestamps elsewhere in the API, so this tries
        // both rather than assuming one.
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            let withFractionalSeconds = ISO8601DateFormatter()
            withFractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = withFractionalSeconds.date(from: string) { return date }
            if let date = ISO8601DateFormatter().date(from: string) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date: \(string)")
        }
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

    /// Expenses shared with `friendId`, newest first, with soft-deleted
    /// entries filtered out — backs the default-friend transaction list in
    /// SplitwiseFriendTransactionsView.
    static func fetchExpenses(friendId: Int, token: String) async throws -> [SplitwiseExpense] {
        let data = try await get("get_expenses", queryItems: [
            URLQueryItem(name: "friend_id", value: String(friendId)),
            URLQueryItem(name: "limit", value: "50"),
        ], token: token)
        return try decoder.decode(SplitwiseExpensesResponse.self, from: data).expenses
            .filter { $0.deletedAt == nil }
            .sorted { $0.date > $1.date }
    }

    /// Recent account activity — the same feed the Splitwise app shows under
    /// "Activity" — newest first, backing SplitwiseActivityView. Capped at the
    /// same 50 entries as `fetchExpenses`; without an explicit `limit`
    /// Splitwise returns the entire history.
    static func fetchNotifications(token: String) async throws -> [SplitwiseNotification] {
        let data = try await get("get_notifications", queryItems: [
            URLQueryItem(name: "limit", value: "50"),
        ], token: token)
        return try decoder.decode(SplitwiseNotificationsResponse.self, from: data).notifications
            .sorted { $0.createdAt > $1.createdAt }
    }

    static func createExpense(_ expense: SplitwiseExpenseRequest, token: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("create_expense"))
        request.httpMethod = Const.HTTP.post
        request.setValue(Const.HTTP.bearer(token), forHTTPHeaderField: Const.HTTP.authorizationHeader)
        request.setValue(Const.HTTP.jsonContentType, forHTTPHeaderField: Const.HTTP.contentTypeHeader)
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

    /// Saves an edited expense via the documented `update_expense` endpoint —
    /// backs the editable total/shares in SplitwiseExpenseDetailView. Returns
    /// the expense as Splitwise stored it, or nil when the response didn't
    /// carry one (the save still succeeded — see the `errors` check — so the
    /// caller re-fetches rather than treating that as a failure).
    static func updateExpense(id: Int, _ expense: SplitwiseExpenseUpdateRequest, token: String) async throws -> SplitwiseExpense? {
        var request = URLRequest(url: baseURL.appendingPathComponent("update_expense/\(id)"))
        request.httpMethod = Const.HTTP.post
        request.setValue(Const.HTTP.bearer(token), forHTTPHeaderField: Const.HTTP.authorizationHeader)
        request.setValue(Const.HTTP.jsonContentType, forHTTPHeaderField: Const.HTTP.contentTypeHeader)
        request.httpBody = try JSONSerialization.data(withJSONObject: expense.asJSONObject)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)

        // Same 200-with-"errors" convention as create_expense (e.g. shares
        // that don't add up to the cost), so a 2xx alone isn't enough here.
        let result = try decoder.decode(SplitwiseUpdateExpenseResponse.self, from: data)
        let messages = result.errors?.values.flatMap { $0 } ?? []
        if !messages.isEmpty {
            throw SplitwiseAPIError.validation(messages.joined(separator: " "))
        }
        return result.expenses?.first
    }

    /// Soft-deletes an expense via Splitwise's documented `delete_expense`
    /// endpoint — used by the detail sheet in SplitwiseFriendTransactionsView.
    static func deleteExpense(id: Int, token: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("delete_expense/\(id)"))
        request.httpMethod = Const.HTTP.post
        request.setValue(Const.HTTP.bearer(token), forHTTPHeaderField: Const.HTTP.authorizationHeader)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)
    }

    /// Brings a soft-deleted expense back via the documented
    /// `undelete_expense` endpoint — backs the Activity feed's "Restore"
    /// action. Splitwise answers 200 even when it refused (e.g. the expense
    /// was already restored), reporting the real outcome in the body's
    /// `success` flag, so a 2xx alone isn't enough here.
    static func undeleteExpense(id: Int, token: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("undelete_expense/\(id)"))
        request.httpMethod = Const.HTTP.post
        request.setValue(Const.HTTP.bearer(token), forHTTPHeaderField: Const.HTTP.authorizationHeader)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)

        // Only an explicit `false` is treated as a failure: a body Relay
        // can't parse (a shape change, an empty response) alongside a 2xx is
        // more likely a success than not, and the caller re-fetches the feed
        // straight after — which shows the truth either way. Guessing
        // "failed" there would put an error in front of a restore that
        // actually worked.
        let result = try? decoder.decode(SplitwiseUndeleteExpenseResponse.self, from: data)
        if result?.success == false {
            throw SplitwiseAPIError.validation("Splitwise wouldn't restore this expense.")
        }
    }

    private static func get(_ path: String, queryItems: [URLQueryItem] = [], token: String) async throws -> Data {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        var request = URLRequest(url: components.url!)
        request.setValue(Const.HTTP.bearer(token), forHTTPHeaderField: Const.HTTP.authorizationHeader)
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
            let retryAfter = http.value(forHTTPHeaderField: Const.HTTP.retryAfterHeader).flatMap(TimeInterval.init)
            throw SplitwiseAPIError.rateLimited(retryAfter: retryAfter)
        default:
            throw SplitwiseAPIError.server(status: http.statusCode)
        }
    }
}
