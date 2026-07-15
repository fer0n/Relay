//
//  YNABAccountCacheStore.swift
//  Hazel
//
//  Caches the last-fetched YNAB account list on disk so the card-to-account
//  picker (in-app and via Shortcuts) can show data instantly and keep
//  working offline, rather than blocking on a live fetch every time. Mirrors
//  YNABCategoryUsageStore.swift's file-storage convention.
//

import Foundation

nonisolated enum YNABAccountCacheStore {
    private static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ynab-account-cache.json")
    }()

    static func load() -> [YNABAccount]? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode([YNABAccount].self, from: data)
    }

    static func save(_ items: [YNABAccount]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Live fetch, updating the cache on success; falls back to the cache
    /// on failure, only rethrowing when the cache is also empty.
    static func fetch(token: String) async throws -> [YNABAccount] {
        do {
            let fresh = try await YNABService.fetchAccounts(token: token)
            save(fresh)
            return fresh
        } catch {
            if let cached = load() { return cached }
            throw error
        }
    }
}
