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
    private static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("splitwise-friend-usage.json")
    }()

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

    /// Most-recently-used first; friends with no recorded usage keep their
    /// original (Splitwise API) relative order, appended after all used ones.
    static func sorted(_ friends: [SplitwiseFriend]) -> [SplitwiseFriend] {
        let lastUsed = load().lastUsedByFriendId
        return friends.enumerated()
            .sorted { lhs, rhs in
                let lhsDate = lastUsed[String(lhs.element.id)]
                let rhsDate = lastUsed[String(rhs.element.id)]
                switch (lhsDate, rhsDate) {
                case let (l?, r?): return l > r
                case (.some, nil): return true
                case (nil, .some): return false
                case (nil, nil): return lhs.offset < rhs.offset
                }
            }
            .map(\.element)
    }
}
