//
//  FileImportHistoryStore.swift
//  Relay
//
//  Remembers the FileImportRow ids that were actually submitted, per
//  destination, so SharedFileImportView can flag a row as "Already
//  imported"/"Already split" when the same statement (or an overlapping date
//  range) is imported again later. Per-destination because splitting a row on
//  Splitwise says nothing about whether it was imported to YNAB. Replaces
//  the Splitwise-only SplitwiseImportHistoryStore; ids are namespaced by
//  destination in one file. Capped rather than growing forever — same
//  Application Support JSON pattern as SplitwiseFriendUsageStore.swift.
//

import Foundation

private let recentLimit = 1000

struct FileImportHistory: Codable {
    /// Each entry is "{destination.rawValue}:{rowId}".
    var recentIds: [String] = []
}

nonisolated enum FileImportHistoryStore {
    private static let fileURL = ApplicationSupportFile.url("file-import-history.json")

    private static func key(_ id: String, _ destination: FileImportDestination) -> String {
        "\(destination.rawValue):\(id)"
    }

    static func load() -> FileImportHistory {
        guard let data = try? Data(contentsOf: fileURL) else { return FileImportHistory() }
        return (try? JSONDecoder().decode(FileImportHistory.self, from: data)) ?? FileImportHistory()
    }

    /// The set of row ids already handled for a destination, for flagging the
    /// review list without a disk read per row.
    static func handledIDs(destination: FileImportDestination) -> Set<String> {
        let prefix = "\(destination.rawValue):"
        return Set(load().recentIds.compactMap { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : nil })
    }

    /// Appends ids not already recorded, then trims to the `recentLimit`
    /// most recently added.
    static func record(_ ids: [String], destination: FileImportDestination) {
        var history = load()
        for id in ids {
            let namespaced = key(id, destination)
            if !history.recentIds.contains(namespaced) {
                history.recentIds.append(namespaced)
            }
        }
        if history.recentIds.count > recentLimit {
            history.recentIds.removeFirst(history.recentIds.count - recentLimit)
        }
        guard let data = try? JSONEncoder().encode(history) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Unions a restored-from-backup history into the current one — ids are
    /// already destination-namespaced, so appending only the not-yet-present
    /// ones and trimming to `recentLimit` keeps the same dedup guarantee as
    /// `record`.
    static func merge(_ incoming: FileImportHistory) {
        var history = load()
        for id in incoming.recentIds where !history.recentIds.contains(id) {
            history.recentIds.append(id)
        }
        if history.recentIds.count > recentLimit {
            history.recentIds.removeFirst(history.recentIds.count - recentLimit)
        }
        guard let data = try? JSONEncoder().encode(history) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
