//
//  SplitwiseRemovalMigration.swift
//  Relay
//
//  One-time cleanup for the release that removed Splitwise, run before
//  anything reads the stores it touches: deletes the tokens and API caches
//  per Splitwise's deletion terms, and clears the queue/history/claims files,
//  which hold a `splitwise` case Swift's enum decoder would choke the whole
//  file on. Templates survive; only their split target is dropped.
//

import Foundation
import os

nonisolated enum SplitwiseRemovalMigration {
    private static let completedKey = "splitwiseRemovalMigration.completed"
    private static let logger = Logger(subsystem: Const.loggerSubsystem, category: "Migration")

    private static let filesToDelete = [
        "splitwise-friend-cache.json",
        "splitwise-group-cache-v2.json",
        "splitwise-notification-cache.json",
        "splitwise-current-user.json",
        "splitwise-default-friend.json",
        "splitwise-friend-usage.json",
        "splitwise-wallet-transaction-config.json",
        "pending-operations.json",
        "transaction-history.json",
        "transaction-claims.json",
        "file-import-staging.json",
        "file-import-history.json",
        "transaction-drafts.json",
    ]

    private static let keychainKeysToDelete = [
        "splitwise.accessToken",
        "splitwise.refreshToken",
    ]

    static func runIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: completedKey) else { return }

        for key in keychainKeysToDelete {
            KeychainStore.delete(for: key)
        }
        for name in filesToDelete {
            try? FileManager.default.removeItem(at: ApplicationSupportFile.url(name))
        }
        // Per-friend expense caches were one file each, named by friend id.
        if let contents = try? FileManager.default.contentsOfDirectory(
            at: ApplicationSupportFile.directory,
            includingPropertiesForKeys: nil
        ) {
            for url in contents where url.lastPathComponent.hasPrefix("splitwise-") {
                try? FileManager.default.removeItem(at: url)
            }
        }

        clearTemplateSplitTargets()

        UserDefaults.standard.set(true, forKey: completedKey)
        logger.log("Splitwise removal migration completed")
    }

    /// Load and re-save: the fields are gone from the type, so a decoded
    /// template no longer has one.
    private static func clearTemplateSplitTargets() {
        let config = WalletTransactionConfigStore.load()
        guard !config.templates.isEmpty else { return }
        try? WalletTransactionConfigStore.save(config)
    }
}
