//
//  YNABCategoryUsageStore.swift
//  Relay
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

    /// Folds a restored-from-backup usage record into the current one,
    /// keeping the more recent last-used date per category so restoring an
    /// older backup can't roll a still-used category back down the picker.
    static func merge(_ incoming: YNABCategoryUsage) {
        var usage = load()
        for (categoryId, date) in incoming.lastUsedByCategoryId {
            if let existing = usage.lastUsedByCategoryId[categoryId] {
                usage.lastUsedByCategoryId[categoryId] = max(existing, date)
            } else {
                usage.lastUsedByCategoryId[categoryId] = date
            }
        }
        guard let data = try? JSONEncoder().encode(usage) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    static func sorted(_ categories: [YNABCategory]) -> [YNABCategory] {
        UsageStore.sorted(categories, lastUsed: load().lastUsedByCategoryId, key: \.id)
    }
}
