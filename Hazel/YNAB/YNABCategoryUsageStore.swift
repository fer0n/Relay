//
//  YNABCategoryUsageStore.swift
//  Hazel
//
//  Tracks when each YNAB category was last used on a created transaction
//  (recorded from AddYNABTransactionIntent/AddWalletTransactionToYNABIntent),
//  so category pickers — Shortcuts' native one via YNABCategoryQuery, and
//  the wallet intent's requestDisambiguation prompt — surface recently-used
//  categories first instead of whatever order the YNAB API returns.
//  Mirrors SplitwiseFriendUsageStore.swift's approach exactly.
//

import Foundation

struct YNABCategoryUsage: Codable {
    var lastUsedByCategoryId: [String: Date] = [:]
}

nonisolated enum YNABCategoryUsageStore {
    private static let fileURL = ApplicationSupportFile.url("ynab-category-usage.json")

    static func load() -> YNABCategoryUsage {
        guard let data = try? Data(contentsOf: fileURL) else { return YNABCategoryUsage() }
        return (try? JSONDecoder().decode(YNABCategoryUsage.self, from: data)) ?? YNABCategoryUsage()
    }

    static func recordUsage(categoryId: String) {
        var usage = load()
        usage.lastUsedByCategoryId[categoryId] = Date()
        guard let data = try? JSONEncoder().encode(usage) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    static func sorted(_ categories: [YNABCategory]) -> [YNABCategory] {
        UsageStore.sorted(categories, lastUsed: load().lastUsedByCategoryId, key: \.id)
    }
}
