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

private struct SplitwiseExpenseCache: Codable {
    let expenses: [SplitwiseExpense]
    let fetchedAt: Date
}

nonisolated enum SplitwiseExpenseCacheStore {
    private static func fileURL(friendId: Int) -> URL {
        ApplicationSupportFile.url("splitwise-expense-cache-\(friendId).json")
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
