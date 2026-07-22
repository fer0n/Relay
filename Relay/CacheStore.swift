//
//  CacheStore.swift
//  Relay
//

import Foundation

nonisolated enum CacheStore {
    /// Shared throttle for the Splitwise balance/expense caches: below this
    /// age, a view's re-run `.task` shows the cache instead of re-fetching
    /// (which would reset the "Last refreshed …" timestamp). Pull-to-refresh
    /// bypasses it. Kept here so the two stores can't drift out of sync.
    static let splitwiseRefreshInterval: TimeInterval = 5 * 60

    /// True once `interval` has passed since `lastFetchedAt`, or there's
    /// never been a fetch (nil).
    static func isStale(_ lastFetchedAt: Date?, interval: TimeInterval = splitwiseRefreshInterval) -> Bool {
        guard let lastFetchedAt else { return true }
        return Date().timeIntervalSince(lastFetchedAt) > interval
    }

    /// Live fetch, updating the cache on success; falls back to the cache
    /// on failure, only rethrowing when the cache is also empty. Shared by
    /// every "fetch live, fall back to disk cache" store (YNAB accounts/
    /// categories, Splitwise friends).
    static func fetch<T>(
        load: () -> T?,
        save: (T) -> Void,
        remote: () async throws -> T
    ) async throws -> T {
        do {
            let fresh = try await remote()
            save(fresh)
            return fresh
        } catch {
            if let cached = load() { return cached }
            throw error
        }
    }
}
