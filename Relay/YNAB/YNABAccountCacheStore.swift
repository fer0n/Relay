//
//  YNABAccountCacheStore.swift
//  Relay
//
//  Caches the last-fetched YNAB account list on disk so the card-to-account
//  picker (in-app and via Shortcuts) can show data instantly and keep
//  working offline, rather than blocking on a live fetch every time. Thin
//  wrapper over the shared FileCache (see CacheStore.swift).
//

import Foundation

nonisolated enum YNABAccountCacheStore {
    private static let cache = FileCache<[YNABAccount]>(fileName: "ynab-account-cache.json")

    static func load() -> [YNABAccount]? { cache.load() }
    static func save(_ items: [YNABAccount]) { cache.save(items) }
    static var isStale: Bool { cache.isStale }

    static func fetch(token: String) async throws -> [YNABAccount] {
        try await cache.fetch { try await YNABService.fetchAccounts(token: token) }
    }
}
