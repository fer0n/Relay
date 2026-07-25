//
//  SplitwiseNotificationCacheStore.swift
//  Relay
//
//  Caches the last-fetched activity feed on disk so SplitwiseActivityView
//  renders instantly (and still shows something offline) instead of blocking
//  on a live fetch every time it's pushed. Thin wrapper over the shared
//  FileCache (see CacheStore.swift), same as SplitwiseFriendCacheStore.
//

import Foundation

nonisolated enum SplitwiseNotificationCacheStore {
    private static let cache = FileCache<[SplitwiseNotification]>(fileName: "splitwise-notification-cache.json")

    static func load() -> [SplitwiseNotification]? { cache.load() }
    static func save(_ items: [SplitwiseNotification]) { cache.save(items) }

    /// When the feed was last actually fetched from Splitwise — shown as
    /// "… ago" in SplitwiseActivityView's footer. Nil until the first
    /// successful `save`.
    static var lastFetchedAt: Date? { cache.lastFetchedAt }

    /// True once `CacheStore.refreshInterval` has passed since the last
    /// successful live fetch, or there's never been one — see there for why
    /// the activity view's `.task` throttles on this.
    static var isStale: Bool { cache.isStale }

    static func fetch(token: String) async throws -> [SplitwiseNotification] {
        try await cache.fetch { try await SplitwiseService.fetchNotifications(token: token) }
    }

    /// Called from `SplitwiseAuthService.signOut()`. This cache in particular
    /// shouldn't outlive the token: unlike the friend/expense caches it holds
    /// Splitwise's own prose about who did what and when, so leaving it on
    /// disk after disconnecting would keep a readable account history around
    /// with no way in the app to see or clear it.
    static func delete() { cache.delete() }
}
