//
//  YNABCategoryCacheStore.swift
//  Hazel
//
//  Caches the last-fetched YNAB category list on disk so template creation
//  and Shortcuts pickers can show data instantly and keep working offline,
//  rather than blocking on a live fetch every time. Mirrors
//  YNABCategoryUsageStore.swift's file-storage convention.
//

import Foundation

nonisolated enum YNABCategoryCacheStore {
    private static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ynab-category-cache.json")
    }()

    static func load() -> [YNABCategory]? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode([YNABCategory].self, from: data)
    }

    static func save(_ items: [YNABCategory]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Live fetch, updating the cache on success; falls back to the cache
    /// on failure, only rethrowing when the cache is also empty.
    static func fetch(token: String) async throws -> [YNABCategory] {
        do {
            let fresh = try await YNABService.fetchCategories(token: token)
            save(fresh)
            return fresh
        } catch {
            if let cached = load() { return cached }
            throw error
        }
    }
}
