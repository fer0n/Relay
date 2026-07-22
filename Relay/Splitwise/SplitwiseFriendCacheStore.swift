//
//  SplitwiseFriendCacheStore.swift
//  Relay
//
//  Caches the last-fetched Splitwise friend list on disk so template
//  creation and Shortcuts pickers can show data instantly and keep working
//  offline, rather than blocking on a live fetch every time. Mirrors
//  SplitwiseFriendUsageStore.swift's file-storage convention.
//

import Foundation

nonisolated enum SplitwiseFriendCacheStore {
    private static let fileURL = ApplicationSupportFile.url("splitwise-friend-cache.json")
    private static let lastFetchedKey = "splitwise.friendCache.lastFetchedAt"

    /// When the friend list (and so each friend's balance) was last
    /// actually fetched from Splitwise — shown as "Last refreshed …" on
    /// ContentView's balance card. Nil until the first successful `save`.
    static var lastFetchedAt: Date? {
        UserDefaults.standard.object(forKey: lastFetchedKey) as? Date
    }

    /// True once `CacheStore.splitwiseRefreshInterval` has passed since the
    /// last successful live fetch, or there's never been one — see there for
    /// why ContentView's `.task` throttles on this.
    static var isStale: Bool { CacheStore.isStale(lastFetchedAt) }

    static func load() -> [SplitwiseFriend]? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode([SplitwiseFriend].self, from: data)
    }

    static func save(_ items: [SplitwiseFriend]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
        UserDefaults.standard.set(Date(), forKey: lastFetchedKey)
    }

    static func fetch(token: String) async throws -> [SplitwiseFriend] {
        try await CacheStore.fetch(load: load, save: save) {
            try await SplitwiseService.fetchFriends(token: token)
        }
    }
}
