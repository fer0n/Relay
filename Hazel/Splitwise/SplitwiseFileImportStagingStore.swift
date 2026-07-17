//
//  SplitwiseFileImportStagingStore.swift
//  Hazel
//
//  Holds the one file import ImportSplitwiseFileIntent most recently parsed
//  but hasn't been reviewed yet — SplitwiseFileImportReviewView reads this
//  to show the multi-select checklist. Same Application Support JSON
//  pattern as SplitwiseDefaultFriendStore.swift. Only one pending import at
//  a time: starting a new Shortcut import overwrites an unreviewed one.
//

import Foundation

struct SplitwiseFileImportStaging: Codable {
    let friendId: Int
    let friendFirstName: String
    let friendFullName: String
    let rows: [SplitwiseImportRow]
    let sourceFilename: String
    let importedAt: Date
}

nonisolated enum SplitwiseFileImportStagingStore {
    private static let fileURL = ApplicationSupportFile.url("splitwise-file-import-staging.json")

    static func load() -> SplitwiseFileImportStaging? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(SplitwiseFileImportStaging.self, from: data)
    }

    static func save(_ staging: SplitwiseFileImportStaging) throws {
        let data = try JSONEncoder().encode(staging)
        try data.write(to: fileURL, options: .atomic)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
