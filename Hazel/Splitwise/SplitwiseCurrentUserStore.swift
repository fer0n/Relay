//
//  SplitwiseCurrentUserStore.swift
//  Hazel
//
//  Caches the signed-in Splitwise user (just id + first name) from the last
//  successful `get_current_user` call, so SplitwiseExpenseHelper can still
//  build an expense request while offline instead of failing before it ever
//  reaches PendingSync's queue-for-later path.
//

import Foundation

nonisolated enum SplitwiseCurrentUserStore {
    private static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("splitwise-current-user.json")
    }()

    static func load() -> SplitwiseUser? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(SplitwiseUser.self, from: data)
    }

    static func save(_ user: SplitwiseUser) throws {
        let data = try JSONEncoder().encode(user)
        try data.write(to: fileURL, options: .atomic)
    }

    static func delete() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
