//
//  SplitwiseImportHistoryStore.swift
//  Hazel
//
//  Remembers the most recent SplitwiseImportRow ids that were actually
//  split, so SplitwiseFileImportReviewView can flag a row as "Already
//  split" when the same statement (or an overlapping date range) is
//  imported again. Capped rather than growing forever — same Application
//  Support JSON pattern as SplitwiseFriendUsageStore.swift.
//

import Foundation

private let recentLimit = 500

struct SplitwiseImportHistory: Codable {
    var recentIds: [String] = []
}

nonisolated enum SplitwiseImportHistoryStore {
    private static let fileURL = ApplicationSupportFile.url("splitwise-import-history.json")

    static func load() -> SplitwiseImportHistory {
        guard let data = try? Data(contentsOf: fileURL) else { return SplitwiseImportHistory() }
        return (try? JSONDecoder().decode(SplitwiseImportHistory.self, from: data)) ?? SplitwiseImportHistory()
    }

    static func contains(_ id: String) -> Bool {
        load().recentIds.contains(id)
    }

    /// Appends ids not already recorded, then trims to the `recentLimit`
    /// most recently added.
    static func recordSplit(ids: [String]) {
        var history = load()
        for id in ids where !history.recentIds.contains(id) {
            history.recentIds.append(id)
        }
        if history.recentIds.count > recentLimit {
            history.recentIds.removeFirst(history.recentIds.count - recentLimit)
        }
        guard let data = try? JSONEncoder().encode(history) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
