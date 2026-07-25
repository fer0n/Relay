//
//  ApplicationSupportFile.swift
//  Relay
//

import Foundation

nonisolated enum ApplicationSupportFile {
    /// Resolves `filename` inside the app's Application Support directory,
    /// creating the directory if needed — shared by every JSON-backed store
    /// (WalletTransactionConfigStore, the YNAB/Splitwise caches, transaction
    /// drafts/history, pending operations, etc.), which otherwise only
    /// differ in load/save/decode behavior, not in how they locate their file.
    static func url(_ filename: String) -> URL {
        directory.appendingPathComponent(filename)
    }

    /// The Application Support directory itself, created if needed — for the
    /// one store whose filenames aren't fixed (SplitwiseExpenseCacheStore
    /// writes one file per friend id) and so has to enumerate them rather
    /// than address each by name.
    static var directory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
