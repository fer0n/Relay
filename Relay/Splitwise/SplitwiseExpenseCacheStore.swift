//
//  SplitwiseExpenseCacheStore.swift
//  Relay
//
//  Caches the last-fetched expense history for the default Splitwise
//  friend, so SplitwiseFriendTransactionsView can show data instantly and
//  keep working offline instead of blocking on a live fetch every time.
//  Mirrors SplitwiseFriendCacheStore.swift's file-storage convention; keyed
//  by friend id (rather than one fixed file, as the friend cache is) so a
//  stale cache from a previously-chosen default friend is never mistaken
//  for the current one.
//

import Foundation

private struct SplitwiseExpenseCache: Codable {
    let friendId: Int
    let expenses: [SplitwiseExpense]
    let fetchedAt: Date
}

nonisolated enum SplitwiseExpenseCacheStore {
    private static let fileURL = ApplicationSupportFile.url("splitwise-expense-cache.json")

    static func load(friendId: Int) -> [SplitwiseExpense]? {
        loadCache(friendId: friendId)?.expenses
    }

    /// True once `CacheStore.splitwiseRefreshInterval` has passed since the
    /// last successful live fetch, or there's never been one — see there for
    /// why SplitwiseFriendTransactionsView's `.task` throttles on this.
    static func isStale(friendId: Int) -> Bool {
        CacheStore.isStale(loadCache(friendId: friendId)?.fetchedAt)
    }

    static func save(friendId: Int, _ expenses: [SplitwiseExpense]) {
        guard let data = try? JSONEncoder().encode(SplitwiseExpenseCache(friendId: friendId, expenses: expenses, fetchedAt: Date())) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    static func fetch(friendId: Int, token: String) async throws -> [SplitwiseExpense] {
        try await CacheStore.fetch(load: { load(friendId: friendId) }, save: { save(friendId: friendId, $0) }) {
            try await SplitwiseService.fetchExpenses(friendId: friendId, token: token)
        }
    }

    private static func loadCache(friendId: Int) -> SplitwiseExpenseCache? {
        guard let data = try? Data(contentsOf: fileURL),
              let cache = try? JSONDecoder().decode(SplitwiseExpenseCache.self, from: data),
              cache.friendId == friendId else { return nil }
        return cache
    }
}
