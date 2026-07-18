//
//  YNABCategoryCacheStore.swift
//  Relay
//
//  Caches the last-fetched YNAB category list on disk so template creation
//  and Shortcuts pickers can show data instantly and keep working offline,
//  rather than blocking on a live fetch every time. Mirrors
//  YNABCategoryUsageStore.swift's file-storage convention.
//

import Foundation

nonisolated enum YNABCategoryCacheStore {
    private static let fileURL = ApplicationSupportFile.url("ynab-category-cache.json")

    static func load() -> [YNABCategory]? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode([YNABCategory].self, from: data)
    }

    static func save(_ items: [YNABCategory]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    static func fetch(token: String) async throws -> [YNABCategory] {
        try await CacheStore.fetch(load: load, save: save) {
            try await YNABService.fetchCategories(token: token)
        }
    }
}
