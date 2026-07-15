//
//  SplitwiseModels.swift
//  Hazel
//
//  Codable models for the subset of the Splitwise API
//  (https://dev.splitwise.com) used to create an expense split with one
//  friend. JSONDecoder uses snake_case conversion, so property names here
//  are plain camelCase.
//

import Foundation

struct SplitwiseUser: Codable {
    let id: Int
    let firstName: String
}

struct SplitwiseFriend: Codable {
    let id: Int
    let firstName: String
    let lastName: String?

    /// Disambiguates friends sharing a first name (e.g. in the default
    /// friend picker in ContentView.swift).
    var fullName: String {
        [firstName, lastName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// Non-group expense split between the signed-in user (who pays the full
/// cost) and one friend, each owing their own share back. Currency mirrors
/// the original Shortcut, which hardcoded EUR. Codable so PendingOperationQueue
/// can persist one to disk while offline.
struct SplitwiseExpenseRequest: Codable {
    let costCents: Int
    let description: String
    let currencyCode: String
    let payerUserId: Int
    let payerOwedCents: Int
    let friendUserId: Int
    let friendOwedCents: Int

    var asJSONObject: [String: Any] {
        [
            "cost": Self.decimalString(costCents),
            "description": description,
            "currency_code": currencyCode,
            "group_id": 0,
            "users__0__user_id": payerUserId,
            "users__0__paid_share": Self.decimalString(costCents),
            "users__0__owed_share": Self.decimalString(payerOwedCents),
            "users__1__user_id": friendUserId,
            "users__1__paid_share": "0.00",
            "users__1__owed_share": Self.decimalString(friendOwedCents),
        ]
    }

    private static func decimalString(_ cents: Int) -> String {
        String(format: "%.2f", Double(cents) / 100)
    }
}

// MARK: - Response envelopes

struct SplitwiseCurrentUserResponse: Codable {
    let user: SplitwiseUser
}

struct SplitwiseFriendsResponse: Codable {
    let friends: [SplitwiseFriend]
}

struct SplitwiseCreateExpenseResponse: Codable {
    let errors: [String: [String]]?
}
