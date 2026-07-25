//
//  YNABCategoryCacheStore.swift
//  Relay
//
//  Caches the last-fetched YNAB category list on disk so template creation
//  and Shortcuts pickers can show data instantly and keep working offline,
//  rather than blocking on a live fetch every time. Thin wrapper over the
//  shared FileCache (see CacheStore.swift).
//

import Foundation

nonisolated enum YNABCategoryCacheStore {
    private static let cache = FileCache<[YNABCategory]>(fileName: "ynab-category-cache.json")

    static func load() -> [YNABCategory]? { cache.load() }
    static func save(_ items: [YNABCategory]) { cache.save(items) }
    static var isStale: Bool { cache.isStale }

    static func fetch(token: String) async throws -> [YNABCategory] {
        try await cache.fetch { try await YNABService.fetchCategories(token: token) }
    }

    /// Called from `YNABAuthService.signOut()` so the category list doesn't
    /// outlive the token it was read with. Deliberately *not* wired into
    /// `invalidateAccessToken()`, which also fires when a token simply
    /// expires — the cache is what keeps the pickers usable until the user
    /// signs back in.
    static func delete() { cache.delete() }
}
