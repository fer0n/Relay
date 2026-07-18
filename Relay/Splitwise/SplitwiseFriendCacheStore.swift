//
//  SplitwiseFriendCacheStore.swift
//  Relay
//
//  Caches the last-fetched Splitwise friend list on disk so template
//  creation and Shortcuts pickers can show data instantly and keep working
//  offline, rather than blocking on a live fetch every time. Mirrors
//  SplitwiseFriendUsageStore.swift's file-storage convention.
//

import Foundation

nonisolated enum SplitwiseFriendCacheStore {
    private static let fileURL = ApplicationSupportFile.url("splitwise-friend-cache.json")

    static func load() -> [SplitwiseFriend]? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode([SplitwiseFriend].self, from: data)
    }

    static func save(_ items: [SplitwiseFriend]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    static func fetch(token: String) async throws -> [SplitwiseFriend] {
        try await CacheStore.fetch(load: load, save: save) {
            try await SplitwiseService.fetchFriends(token: token)
        }
    }
}
