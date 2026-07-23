//
//  CacheStore.swift
//  Relay
//

import Foundation

nonisolated enum CacheStore {
    /// Shared throttle for the on-disk caches: below this age, a view's
    /// re-run `.task` (or a picker re-opening) shows the cache instead of
    /// re-fetching — keeping navigation cheap and staying well under the
    /// YNAB/Splitwise rate limits. Pull-to-refresh bypasses it. Kept here so
    /// the stores can't drift out of sync.
    static let refreshInterval: TimeInterval = 5 * 60

    /// True once `interval` has passed since `lastFetchedAt`, or there's
    /// never been a fetch (nil).
    static func isStale(_ lastFetchedAt: Date?, interval: TimeInterval = refreshInterval) -> Bool {
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

/// A file-backed cache of a single `Codable` value plus the timestamp of its
/// last successful live fetch. Collapses the YNAB category/account and
/// Splitwise friend caches — previously identical `load`/`save`/`fetch`
/// boilerplate — into one type, and gives them all a uniform `isStale` so
/// every call site can throttle re-fetching the same way. (The expense cache
/// stays separate: it's a single slot keyed by friend id, not a plain list.)
nonisolated struct FileCache<Value: Codable> {
    private let fileURL: URL
    private let lastFetchedKey: String

    init(fileName: String) {
        fileURL = ApplicationSupportFile.url(fileName)
        lastFetchedKey = "cache.\(fileName).lastFetchedAt"
    }

    func load() -> Value? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    func save(_ value: Value) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: fileURL, options: .atomic)
        UserDefaults.standard.set(Date(), forKey: lastFetchedKey)
    }

    /// When `save` last ran (i.e. the last successful live fetch), or nil if
    /// never — e.g. shown as "… ago" on ContentView's balance card.
    var lastFetchedAt: Date? {
        UserDefaults.standard.object(forKey: lastFetchedKey) as? Date
    }

    /// True once `CacheStore.refreshInterval` has passed since the last live
    /// fetch, or there's never been one.
    var isStale: Bool { CacheStore.isStale(lastFetchedAt) }

    /// Live fetch through `CacheStore.fetch`: updates the cache + timestamp
    /// on success, falls back to disk on failure.
    func fetch(remote: () async throws -> Value) async throws -> Value {
        try await CacheStore.fetch(load: load, save: save, remote: remote)
    }
}
