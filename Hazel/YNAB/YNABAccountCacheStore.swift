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
    private static let fileURL = ApplicationSupportFile.url("ynab-account-cache.json")

    static func load() -> [YNABAccount]? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode([YNABAccount].self, from: data)
    }

    static func save(_ items: [YNABAccount]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    static func fetch(token: String) async throws -> [YNABAccount] {
        try await CacheStore.fetch(load: load, save: save) {
            try await YNABService.fetchAccounts(token: token)
        }
    }
}
