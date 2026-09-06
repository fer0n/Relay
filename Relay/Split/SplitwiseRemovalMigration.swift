//
//  SplitwiseRemovalMigration.swift
//  Relay
//
//  One-time cleanup for the release that removed Splitwise, run before
//  anything reads the stores it touches. Two jobs:
//
//  * **Deleting what's now unreachable** — the OAuth tokens and every cache of
//    data pulled from the API, per Splitwise's own deletion terms.
//  * **Clearing what would now fail to decode** — the queue, history and
//    claims files can hold a `splitwise` case, and Swift's enum decoder fails
//    the whole file on an unknown one. They'd reset themselves anyway.
//
//  Templates survive; only their split target is dropped.
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

    /// Load and re-save is enough: the target's fields are gone from the
    /// type, so a decoded template no longer has one.
    private static func clearTemplateSplitTargets() {
        let config = WalletTransactionConfigStore.load()
        guard !config.templates.isEmpty else { return }
        try? WalletTransactionConfigStore.save(config)
    }
}
