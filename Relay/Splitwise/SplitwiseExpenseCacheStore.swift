//
//  SplitwiseExpenseCacheStore.swift
//  Relay
//
//  Caches each friend's last-fetched expense history separately, so
//  SplitwiseFriendTransactionsView can show data instantly and keep working
//  offline instead of blocking on a live fetch every time. Mirrors
//  SplitwiseFriendCacheStore.swift's file-storage convention, but one file
//  per friend id (rather than the friend cache's single fixed file) so
//  viewing several friends' histories — from the default friend's card and
//  now the Balances grid — doesn't have each one evict the last one's cache.
//

import Foundation

private nonisolated struct SplitwiseExpenseCache: Codable {
    let expenses: [SplitwiseExpense]
    let fetchedAt: Date
}

nonisolated enum SplitwiseExpenseCacheStore {
    private static let filenamePrefix = "splitwise-expense-cache-"

    private static func fileURL(friendId: Int) -> URL {
        ApplicationSupportFile.url("\(filenamePrefix)\(friendId).json")
    }

    /// Drops every friend's cached expense list, so the next visit to any
    /// friend's history re-fetches instead of waiting out its staleness
    /// window. Used when an expense changes outside of that friend's own
    /// screen and there's no way to tell whose cache it belongs to — the
    /// Activity feed's "Restore" only knows the expense id, not the friend.
    static func invalidateAll() {
        let directory = ApplicationSupportFile.directory
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.lastPathComponent.hasPrefix(filenamePrefix) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    static func load(friendId: Int) -> [SplitwiseExpense]? {
        loadCache(friendId: friendId)?.expenses
    }

    /// True once `CacheStore.refreshInterval` has passed since the
    /// last successful live fetch, or there's never been one — see there for
    /// why SplitwiseFriendTransactionsView's `.task` throttles on this.
    static func isStale(friendId: Int) -> Bool {
        CacheStore.isStale(loadCache(friendId: friendId)?.fetchedAt)
    }

    static func save(friendId: Int, _ expenses: [SplitwiseExpense]) {
        guard let data = try? JSONEncoder().encode(SplitwiseExpenseCache(expenses: expenses, fetchedAt: Date())) else { return }
        try? data.write(to: fileURL(friendId: friendId), options: .atomic)
    }

    /// When `friendId`'s expenses were last successfully live-fetched, or nil
    /// if never — shown as "… ago" at the bottom of
    /// SplitwiseFriendTransactionsView, same as the friend cache's
    /// `lastFetchedAt` on the balance card/grid.
    static func lastFetchedAt(friendId: Int) -> Date? {
        loadCache(friendId: friendId)?.fetchedAt
    }

    static func fetch(friendId: Int, token: String) async throws -> [SplitwiseExpense] {
        try await CacheStore.fetch(load: { load(friendId: friendId) }, save: { save(friendId: friendId, $0) }) {
            try await SplitwiseService.fetchExpenses(friendId: friendId, token: token)
        }
    }

    private static func loadCache(friendId: Int) -> SplitwiseExpenseCache? {
        guard let data = try? Data(contentsOf: fileURL(friendId: friendId)) else { return nil }
        return try? JSONDecoder().decode(SplitwiseExpenseCache.self, from: data)
    }
}
