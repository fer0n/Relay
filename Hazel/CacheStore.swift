//
//  CacheStore.swift
//  Hazel
//

import Foundation

nonisolated enum CacheStore {
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
