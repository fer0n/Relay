//
//  TemplateImportService.swift
//  Relay
//

import Foundation
import os

private let logger = Logger(subsystem: "com.pentlandFirth.Relay", category: "TemplateImportService")

/// Shared template-import logic used by both `SettingsView`'s "Import
/// Templates" button and the onboarding wizard's import page — parsing and
/// merge behavior lives here once so the two UIs can't drift apart.
struct TemplateImportError: Error {
    let message: String
}

enum TemplateImportService {
    static func importBuckets(from url: URL) async -> Result<String, TemplateImportError> {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

        do {
            let data = try Data(contentsOf: url)
            return await importBuckets(from: data)
        } catch {
            logger.error("failed to read buckets file: \(String(describing: error), privacy: .public)")
            return .failure(TemplateImportError(message: "Failed to import: \(error.localizedDescription)"))
        }
    }

    static func importBuckets(from data: Data) async -> Result<String, TemplateImportError> {
        do {
            // Tried newest-format-first. A full backup (BackupData) must come
            // before the bare WalletTransactionConfig probe: BackupData is the
            // only shape carrying `formatVersion`, whereas WalletTransactionConfig's
            // fields all default, so a backup handed to the config decoder
            // would decode as an empty config and silently import nothing.
            if let backup = BackupService.decodeBackup(from: data) {
                let result = try BackupService.restore(backup)
                logger.log("imported full backup v\(backup.formatVersion, privacy: .public)")
                return .success(BackupService.summary(for: result))
            }

            // Then Relay's older template-only export shape (a full
            // WalletTransactionConfig — no field translation needed), and
            // only falling back to the legacy bucket shape if that fails to
            // decode. The two are structurally distinct (different field
            // names on `merchants`), so this never misidentifies one as the
            // other.
            if let nativeConfig = try? JSONDecoder().decode(WalletTransactionConfig.self, from: data) {
                var config = WalletTransactionConfigStore.load()
                let result = BucketImporter.mergeNative(nativeConfig, into: &config)
                try WalletTransactionConfigStore.save(config)
                logger.log("imported native export: \(result.importedTemplateCount, privacy: .public) templates, \(result.importedMerchantCount, privacy: .public) merchants")
                return .success(summary(for: result))
            }

            let file = try JSONDecoder().decode(BucketImportFile.self, from: data)

            var categories = YNABCategoryCacheStore.load() ?? []
            if let token = await YNABAuthService.validAccessToken(),
                let fetched = try? await YNABCategoryCacheStore.fetch(token: token) {
                categories = fetched
            }

            var config = WalletTransactionConfigStore.load()
            let result = BucketImporter.merge(file, into: &config, categories: categories)
            try WalletTransactionConfigStore.save(config)

            logger.log("imported \(result.importedBucketCount, privacy: .public) buckets, \(result.importedMerchantCount, privacy: .public) merchants")
            return .success(summary(for: result))
        } catch {
            logger.error("failed to import buckets file: \(String(describing: error), privacy: .public)")
            return .failure(TemplateImportError(message: "Failed to import: \(error.localizedDescription)"))
        }
    }

    private static func summary(for result: BucketImporter.Result) -> String {
        var message = "Imported \(result.importedBucketCount) bucket\(result.importedBucketCount == 1 ? "" : "s") and \(result.importedMerchantCount) merchant\(result.importedMerchantCount == 1 ? "" : "s")."
        if !result.unresolvedCategoryNames.isEmpty {
            message += " Couldn't match category: \(result.unresolvedCategoryNames.joined(separator: ", "))."
        }
        if result.skippedCardCount > 0 {
            message += " Skipped \(result.skippedCardCount) card mapping\(result.skippedCardCount == 1 ? "" : "s") — cards are linked automatically the first time you use them."
        }
        return message
    }

    private static func summary(for result: BucketImporter.NativeMergeResult) -> String {
        "Imported \(result.importedTemplateCount) template\(result.importedTemplateCount == 1 ? "" : "s"), \(result.importedMerchantCount) merchant\(result.importedMerchantCount == 1 ? "" : "s"), and \(result.importedCardCount) card\(result.importedCardCount == 1 ? "" : "s")."
    }
}
