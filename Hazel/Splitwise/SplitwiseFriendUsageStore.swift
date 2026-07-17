//
//  SplitwiseFriendUsageStore.swift
//  Hazel
//
//  Tracks when each Splitwise friend was last used to create an expense
//  (recorded from SplitwiseExpenseHelper.addExpense), so friend pickers —
//  Shortcuts' native one via SplitwiseFriendQuery, and ContentView's default
//  friend row — can surface recently-used friends first instead of
//  whatever order the Splitwise API happens to return.
//

import Foundation

struct SplitwiseFriendUsage: Codable {
    var lastUsedByFriendId: [String: Date] = [:]
}

nonisolated enum SplitwiseFriendUsageStore {
    private static let fileURL = ApplicationSupportFile.url("splitwise-friend-usage.json")

    static func load() -> SplitwiseFriendUsage {
        guard let data = try? Data(contentsOf: fileURL) else { return SplitwiseFriendUsage() }
        return (try? JSONDecoder().decode(SplitwiseFriendUsage.self, from: data)) ?? SplitwiseFriendUsage()
    }

    static func recordUsage(friendId: Int) {
        var usage = load()
        usage.lastUsedByFriendId[String(friendId)] = Date()
        guard let data = try? JSONEncoder().encode(usage) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    static func sorted(_ friends: [SplitwiseFriend]) -> [SplitwiseFriend] {
        UsageStore.sorted(friends, lastUsed: load().lastUsedByFriendId, key: { String($0.id) })
    }
}
