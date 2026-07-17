//
//  SplitwiseDefaultFriendStore.swift
//  Hazel
//
//  A single app-wide default Splitwise friend, configured once in Hazel's
//  UI (see ContentView.swift) instead of being asked live every time
//  AddWalletTransactionToYNABIntent wants to split a transaction. Same
//  Application Support JSON pattern as WalletTransactionConfigStore.swift.
//

import Foundation

struct SplitwiseDefaultFriend: Codable {
    let id: Int
    let firstName: String
    /// Shown in ContentView as the current selection; AddWalletTransactionToYNABIntent
    /// uses `firstName` instead when building prompts/dialogs.
    let fullName: String
}

nonisolated enum SplitwiseDefaultFriendStore {
    private static let fileURL = ApplicationSupportFile.url("splitwise-default-friend.json")

    static func load() -> SplitwiseDefaultFriend? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(SplitwiseDefaultFriend.self, from: data)
    }

    static func save(_ friend: SplitwiseDefaultFriend) throws {
        let data = try JSONEncoder().encode(friend)
        try data.write(to: fileURL, options: .atomic)
    }

    static func delete() throws {
        try FileManager.default.removeItem(at: fileURL)
    }
}
