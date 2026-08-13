//
//  SplitwiseGroupCacheStore.swift
//  Relay
//
//  Caches the last-fetched Splitwise group list on disk, so the participant
//  picker can offer groups instantly and keep working offline. Same shape as
//  SplitwiseFriendCacheStore — see there.
//

import Foundation

nonisolated enum SplitwiseGroupCacheStore {
    // `-v2` because SplitwiseGroup gained the simplify-debts fields after the
    // first version shipped a cache: those decode as nil from an older file, so
    // a still-fresh one would keep the group cards on raw member balances until
    // it aged out. A new filename retires them outright instead.
    private static let cache = FileCache<[SplitwiseGroup]>(fileName: "splitwise-group-cache-v2.json")

    static func load() -> [SplitwiseGroup]? { cache.load() }
    static func save(_ items: [SplitwiseGroup]) { cache.save(items) }

    static var lastFetchedAt: Date? { cache.lastFetchedAt }
    static var isStale: Bool { cache.isStale }

    static func fetch(token: String) async throws -> [SplitwiseGroup] {
        try await cache.fetch { try await SplitwiseService.fetchGroups(token: token) }
    }

    /// Called from `SplitwiseAuthService.signOut()` so the group list doesn't
    /// outlive the token it was read with.
    static func delete() { cache.delete() }
}
