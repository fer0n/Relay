//
//  ApplicationSupportFile.swift
//  Hazel
//

import Foundation

nonisolated enum ApplicationSupportFile {
    /// Resolves `filename` inside the app's Application Support directory,
    /// creating the directory if needed — shared by every JSON-backed store
    /// (WalletTransactionConfigStore, the YNAB/Splitwise caches, transaction
    /// drafts/history, pending operations, etc.), which otherwise only
    /// differ in load/save/decode behavior, not in how they locate their file.
    static func url(_ filename: String) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(filename)
    }
}
