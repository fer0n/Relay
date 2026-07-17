//
//  FileImportStagingStore.swift
//  Hazel
//
//  The single pending file import awaiting review in SharedFileImportView —
//  whichever was most recently parsed, by the share-sheet flow or
//  ImportSplitwiseFileIntent. Replaces the old parallel
//  YNAB/Splitwise-specific staging stores: there's now one list of rows both
//  destinations share, plus the remembered destination and per-destination
//  target settings, so flipping "Import To" never rebuilds or loses the
//  list. Only one pending import at a time — a new parse overwrites an
//  unreviewed one. Same Application Support JSON pattern as the stores it
//  replaces; decode is lenient so a file written by an older build (missing
//  newer fields) still loads instead of failing outright.
//

import Foundation

struct FileImportStaging: Codable {
    /// The destination currently under review — remembered so reopening
    /// lands back on the side the user last looked at.
    var destination: FileImportDestination
    var rows: [FileImportRow]
    /// Persists the review checklist's selection across a dismiss/reopen.
    /// Shared across destinations (the same rows are selected whether you're
    /// looking at the YNAB or Splitwise view).
    var selectedIDs: Set<String>
    let sourceFilename: String
    let importedAt: Date

    // Remembered target/settings per side, so reopening restores them.
    var accountId: String?
    var includeMemos: Bool
    var friendId: Int?
    var friendFirstName: String?
    var friendFullName: String?

    init(
        destination: FileImportDestination,
        rows: [FileImportRow],
        selectedIDs: Set<String>,
        sourceFilename: String,
        importedAt: Date,
        accountId: String? = nil,
        includeMemos: Bool = true,
        friendId: Int? = nil,
        friendFirstName: String? = nil,
        friendFullName: String? = nil
    ) {
        self.destination = destination
        self.rows = rows
        self.selectedIDs = selectedIDs
        self.sourceFilename = sourceFilename
        self.importedAt = importedAt
        self.accountId = accountId
        self.includeMemos = includeMemos
        self.friendId = friendId
        self.friendFirstName = friendFirstName
        self.friendFullName = friendFullName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        destination = try container.decodeIfPresent(FileImportDestination.self, forKey: .destination) ?? .ynab
        rows = try container.decode([FileImportRow].self, forKey: .rows)
        selectedIDs = try container.decodeIfPresent(Set<String>.self, forKey: .selectedIDs) ?? []
        sourceFilename = try container.decode(String.self, forKey: .sourceFilename)
        importedAt = try container.decode(Date.self, forKey: .importedAt)
        accountId = try container.decodeIfPresent(String.self, forKey: .accountId)
        includeMemos = try container.decodeIfPresent(Bool.self, forKey: .includeMemos) ?? true
        friendId = try container.decodeIfPresent(Int.self, forKey: .friendId)
        friendFirstName = try container.decodeIfPresent(String.self, forKey: .friendFirstName)
        friendFullName = try container.decodeIfPresent(String.self, forKey: .friendFullName)
    }
}

nonisolated enum FileImportStagingStore {
    private static let fileURL = ApplicationSupportFile.url("file-import-staging.json")

    static func load() -> FileImportStaging? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(FileImportStaging.self, from: data)
    }

    static func save(_ staging: FileImportStaging) throws {
        let data = try JSONEncoder().encode(staging)
        try data.write(to: fileURL, options: .atomic)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
