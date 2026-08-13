//
//  SplitwiseExpenseCacheStore.swift
//  Relay
//
//  Caches each friend's and group's last-fetched expense history separately,
//  so SplitwiseTransactionsView can show data instantly and keep working
//  offline instead of blocking on a live fetch every time. Mirrors
//  SplitwiseFriendCacheStore.swift's file-storage convention, but one file per
//  scope (rather than the friend cache's single fixed file) so viewing several
//  histories — from the default friend's card and the Balances grid — doesn't
//  have each one evict the last one's cache.
//

import Foundation

private nonisolated struct SplitwiseExpenseCache: Codable {
    let expenses: [SplitwiseExpense]
    let fetchedAt: Date
}

/// Whose expense history is being read: everything shared with one friend, or
/// everything posted to one group. Splitwise fetches these through the same
/// `get_expenses` endpoint under different query items, and they cache and
/// render identically, so they travel together rather than as two parallel
/// stacks of near-identical code.
nonisolated enum SplitwiseExpenseScope: Hashable {
    case friend(id: Int)
    case group(id: Int)

    /// Distinguishes the two in cache filenames. Friend ids stay bare, matching
    /// the filenames written before groups existed.
    var cacheKey: String {
        switch self {
        case .friend(let id): "\(id)"
        case .group(let id): "group-\(id)"
        }
    }

    var queryItem: URLQueryItem {
        switch self {
        case .friend(let id): URLQueryItem(name: "friend_id", value: String(id))
        case .group(let id): URLQueryItem(name: "group_id", value: String(id))
        }
    }
}

nonisolated enum SplitwiseExpenseCacheStore {
    private static let filenamePrefix = "splitwise-expense-cache-"

    private static func fileURL(_ scope: SplitwiseExpenseScope) -> URL {
        ApplicationSupportFile.url("\(filenamePrefix)\(scope.cacheKey).json")
    }

    /// Drops every cached expense list, so the next visit to any history
    /// re-fetches instead of waiting out its staleness window. Used when an
    /// expense changes outside of its own screen and there's no way to tell
    /// whose cache it belongs to — the Activity feed's "Restore" only knows the
    /// expense id, not the friend or group.
    static func invalidateAll() {
        let directory = ApplicationSupportFile.directory
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.lastPathComponent.hasPrefix(filenamePrefix) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    static func load(_ scope: SplitwiseExpenseScope) -> [SplitwiseExpense]? {
        loadCache(scope)?.expenses
    }

    /// True once `CacheStore.refreshInterval` has passed since the
    /// last successful live fetch, or there's never been one — see there for
    /// why SplitwiseTransactionsView's `.task` throttles on this.
    static func isStale(_ scope: SplitwiseExpenseScope) -> Bool {
        CacheStore.isStale(loadCache(scope)?.fetchedAt)
    }

    static func save(_ scope: SplitwiseExpenseScope, _ expenses: [SplitwiseExpense]) {
        guard let data = try? JSONEncoder().encode(SplitwiseExpenseCache(expenses: expenses, fetchedAt: Date())) else { return }
        try? data.write(to: fileURL(scope), options: .atomic)
    }

    /// When this scope's expenses were last successfully live-fetched, or nil
    /// if never — shown as "… ago" on the balance card, same as the friend
    /// cache's `lastFetchedAt` on the grid.
    static func lastFetchedAt(_ scope: SplitwiseExpenseScope) -> Date? {
        loadCache(scope)?.fetchedAt
    }

    static func fetch(_ scope: SplitwiseExpenseScope, token: String) async throws -> [SplitwiseExpense] {
        try await CacheStore.fetch(load: { load(scope) }, save: { save(scope, $0) }) {
            try await SplitwiseService.fetchExpenses(scope, token: token)
        }
    }

    private static func loadCache(_ scope: SplitwiseExpenseScope) -> SplitwiseExpenseCache? {
        guard let data = try? Data(contentsOf: fileURL(scope)) else { return nil }
        return try? JSONDecoder().decode(SplitwiseExpenseCache.self, from: data)
    }
}
