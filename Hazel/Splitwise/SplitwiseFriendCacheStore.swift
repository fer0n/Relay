//
//  SplitwiseFriendCacheStore.swift
//  Hazel
//
//  Caches the last-fetched Splitwise friend list on disk so template
//  creation and Shortcuts pickers can show data instantly and keep working
//  offline, rather than blocking on a live fetch every time. Mirrors
//  SplitwiseFriendUsageStore.swift's file-storage convention.
//

import Foundation

nonisolated enum SplitwiseFriendCacheStore {
    private static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("splitwise-friend-cache.json")
    }()

    static func load() -> [SplitwiseFriend]? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode([SplitwiseFriend].self, from: data)
    }

    static func save(_ items: [SplitwiseFriend]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Live fetch, updating the cache on success; falls back to the cache
    /// on failure, only rethrowing when the cache is also empty.
    static func fetch(token: String) async throws -> [SplitwiseFriend] {
        do {
            let fresh = try await SplitwiseService.fetchFriends(token: token)
            save(fresh)
            return fresh
        } catch {
            if let cached = load() { return cached }
            throw error
        }
    }
}
