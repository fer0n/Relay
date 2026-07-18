//
//  BackupService.swift
//  Relay
//
//  Gathers every backed-up store into a BackupData for export, and restores
//  one back onto the stores. Restore is additive (a merge, not a wipe): keys
//  present in the backup overwrite their counterparts, everything else is
//  left alone, so restoring onto a non-empty install never silently drops
//  data the backup didn't happen to include. See BackupData.swift for what
//  is and isn't covered, and why.
//

import Foundation
import os

private let logger = Logger(subsystem: "com.octabits.relay", category: "BackupService")

enum BackupService {
    /// Human-readable and byte-stable across exports of unchanged data — this
    /// is a backup a user might open or diff by hand, not a wire format, so
    /// there's no cost to the extra whitespace. `.iso8601` keeps the usage
    /// stores' dates legible instead of raw reference-date doubles.
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Snapshots every backed-up store into one value.
    static func makeBackup() -> BackupData {
        BackupData(
            formatVersion: BackupData.currentVersion,
            walletTransactionConfig: WalletTransactionConfigStore.load(),
            fileImportConfig: FileImportConfigStore.load(),
            splitwiseDefaultFriend: SplitwiseDefaultFriendStore.load(),
            notificationsEnabled: NotificationsPreferenceStore.isEnabled,
            ynabCategoryUsage: YNABCategoryUsageStore.load(),
            splitwiseFriendUsage: SplitwiseFriendUsageStore.load(),
            fileImportHistory: FileImportHistoryStore.load()
        )
    }

    static func exportData() throws -> Data {
        try encoder.encode(makeBackup())
    }

    /// Decodes a full backup, or returns nil if `data` isn't one — lets
    /// TemplateImportService probe for the backup format before falling back
    /// to the older template/bucket shapes. Uses the same date strategy as
    /// `exportData`, so a round-trip preserves usage timestamps exactly.
    static func decodeBackup(from data: Data) -> BackupData? {
        try? decoder.decode(BackupData.self, from: data)
    }

    struct RestoreResult {
        var importedTemplateCount = 0
        var importedMerchantCount = 0
        var importedCardCount = 0
        var importedMappingCount = 0
        var restoredDefaultFriend = false
        var restoredNotificationsSetting = false
        var restoredUsageCount = 0
        var restoredImportHistoryCount = 0
    }

    static func restore(_ backup: BackupData) throws -> RestoreResult {
        var result = RestoreResult()

        if let incoming = backup.walletTransactionConfig {
            var config = WalletTransactionConfigStore.load()
            let merge = BucketImporter.mergeNative(incoming, into: &config)
            try WalletTransactionConfigStore.save(config)
            result.importedTemplateCount = merge.importedTemplateCount
            result.importedMerchantCount = merge.importedMerchantCount
            result.importedCardCount = merge.importedCardCount
        }

        if let incoming = backup.fileImportConfig {
            var config = FileImportConfigStore.load()
            for (key, mapping) in incoming.csvMappings { config.csvMappings[key] = mapping }
            for (key, format) in incoming.qifDateFormats { config.qifDateFormats[key] = format }
            try FileImportConfigStore.save(config)
            result.importedMappingCount = incoming.csvMappings.count + incoming.qifDateFormats.count
        }

        if let friend = backup.splitwiseDefaultFriend {
            try SplitwiseDefaultFriendStore.save(friend)
            result.restoredDefaultFriend = true
        }

        if let enabled = backup.notificationsEnabled {
            NotificationsPreferenceStore.isEnabled = enabled
            result.restoredNotificationsSetting = true
        }

        if let usage = backup.ynabCategoryUsage {
            YNABCategoryUsageStore.merge(usage)
            result.restoredUsageCount += usage.lastUsedByCategoryId.count
        }

        if let usage = backup.splitwiseFriendUsage {
            SplitwiseFriendUsageStore.merge(usage)
            result.restoredUsageCount += usage.lastUsedByFriendId.count
        }

        if let history = backup.fileImportHistory {
            FileImportHistoryStore.merge(history)
            result.restoredImportHistoryCount = history.recentIds.count
        }

        logger.log("restored backup v\(backup.formatVersion, privacy: .public): \(result.importedTemplateCount, privacy: .public) templates, \(result.importedMerchantCount, privacy: .public) merchants, \(result.importedCardCount, privacy: .public) cards")
        return result
    }

    /// A one-line summary of a restore, listing only the parts that carried
    /// something. Mirrors TemplateImportService's summary phrasing.
    static func summary(for result: RestoreResult) -> String {
        var parts: [String] = []
        if result.importedTemplateCount > 0 {
            parts.append("\(result.importedTemplateCount) template\(plural(result.importedTemplateCount))")
        }
        if result.importedMerchantCount > 0 {
            parts.append("\(result.importedMerchantCount) merchant\(plural(result.importedMerchantCount))")
        }
        if result.importedCardCount > 0 {
            parts.append("\(result.importedCardCount) card\(plural(result.importedCardCount))")
        }
        if result.importedMappingCount > 0 {
            parts.append("\(result.importedMappingCount) import mapping\(plural(result.importedMappingCount))")
        }
        if result.restoredDefaultFriend {
            parts.append("default friend")
        }
        if result.restoredNotificationsSetting {
            parts.append("notification setting")
        }
        if result.restoredUsageCount > 0 {
            parts.append("usage history")
        }
        if result.restoredImportHistoryCount > 0 {
            parts.append("import history")
        }

        guard !parts.isEmpty else { return "Backup restored — nothing to import." }
        return "Restored " + parts.joined(separator: ", ") + "."
    }

    private static func plural(_ count: Int) -> String { count == 1 ? "" : "s" }
}
