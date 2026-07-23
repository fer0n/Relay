//
//  SplitwiseFriendCacheStore.swift
//  Relay
//
//  Caches the last-fetched Splitwise friend list on disk so template
//  creation and Shortcuts pickers can show data instantly and keep working
//  offline, rather than blocking on a live fetch every time. Thin wrapper
//  over the shared FileCache (see CacheStore.swift).
//

import Foundation

nonisolated enum SplitwiseFriendCacheStore {
    private static let cache = FileCache<[SplitwiseFriend]>(fileName: "splitwise-friend-cache.json")

    static func load() -> [SplitwiseFriend]? { cache.load() }
    static func save(_ items: [SplitwiseFriend]) { cache.save(items) }

    /// When the friend list (and so each friend's balance) was last actually
    /// fetched from Splitwise — shown as "… ago" on ContentView's balance
    /// card. Nil until the first successful `save`.
    static var lastFetchedAt: Date? { cache.lastFetchedAt }

    /// True once `CacheStore.refreshInterval` has passed since the last
    /// successful live fetch, or there's never been one — see there for why
    /// the balance/transaction views throttle on this.
    static var isStale: Bool { cache.isStale }

    static func fetch(token: String) async throws -> [SplitwiseFriend] {
        try await cache.fetch { try await SplitwiseService.fetchFriends(token: token) }
    }
}
