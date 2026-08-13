//
//  SplitwiseDefaultFriendStore.swift
//  Relay
//
//  A single app-wide default Splitwise split target, configured once in
//  Relay's UI (see ContentView.swift) instead of being asked live every time
//  AddWalletTransactionToYNABIntent wants to split a transaction. It can be a
//  group as well as a friend. Same Application Support JSON pattern as
//  WalletTransactionConfigStore.swift.
//

import Foundation

nonisolated struct SplitwiseDefaultFriend: Codable {
    let id: Int
    let firstName: String
    /// Shown in ContentView as the current selection; AddWalletTransactionToYNABIntent
    /// uses `firstName` instead when building prompts/dialogs.
    let fullName: String
    /// Whether the fields above name a group. Splitwise numbers friends and
    /// groups separately, so the id alone can't say.
    let isGroup: Bool

    init(id: Int, firstName: String, fullName: String, isGroup: Bool = false) {
        self.id = id
        self.firstName = firstName
        self.fullName = fullName
        self.isGroup = isGroup
    }

    /// Tolerant of files written before `isGroup` existed — the synthesized
    /// decoder would throw `keyNotFound` on every one of them, silently
    /// dropping a configured default.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        firstName = try container.decode(String.self, forKey: .firstName)
        fullName = try container.decode(String.self, forKey: .fullName)
        isGroup = try container.decodeIfPresent(Bool.self, forKey: .isGroup) ?? false
    }
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
