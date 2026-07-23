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
}
