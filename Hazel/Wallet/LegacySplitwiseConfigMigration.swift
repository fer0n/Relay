//
//  LegacySplitwiseConfigMigration.swift
//  Hazel
//
//  One-time migration for users who had templates from before YNAB and
//  Splitwise templates were unified into a single WalletTransactionConfig.
//  Runs transparently from WalletTransactionConfigStore.load(); the legacy
//  file is renamed (not deleted) once merged in, so this never re-runs and
//  nothing is lost even if the merge logic below turns out to be wrong.
//

import Foundation
import os

private let logger = Logger(subsystem: "com.pentlandFirth.Hazel", category: "LegacySplitwiseConfigMigration")

enum LegacySplitwiseConfigMigration {
    private static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("splitwise-wallet-transaction-config.json")
    }()

    private struct LegacyConfig: Codable {
        struct MerchantInfo: Codable {
            var expenseDescription: String
            var templateName: String
        }

        struct Template: Codable {
            var friendId: Int
            var friendFirstName: String
            var friendFullName: String
            var splitOption: SplitwiseTemplateOption = .never
            var autoMatch: [AutoMatchRule] = []
        }

        struct AutoMatchRule: Codable {
            var pattern: String
            var expenseDescription: String
        }

        var merchants: [String: MerchantInfo] = [:]
        var templates: [String: Template] = [:]
    }

    /// Merges the legacy config into `config` and renames the legacy file so
    /// this doesn't run again. Returns nil (no-op) if there's nothing to
    /// migrate, or if it exists but fails to decode (left in place so a
    /// fixed decoder could still recover it later).
    static func mergeIfNeeded(into config: WalletTransactionConfig) -> WalletTransactionConfig? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        guard let legacy = try? JSONDecoder().decode(LegacyConfig.self, from: data) else {
            logger.error("legacy Splitwise config exists but failed to decode — leaving it in place")
            return nil
        }

        var merged = config
        for (name, legacyTemplate) in legacy.templates {
            var template = merged.templates[name] ?? WalletTransactionConfig.Template()
            let isNewTemplate = merged.templates[name] == nil
            if template.splitwiseFriendId == nil {
                template.splitwiseFriendId = legacyTemplate.friendId
                template.splitwiseFriendFirstName = legacyTemplate.friendFirstName
                template.splitwiseFriendFullName = legacyTemplate.friendFullName
            }
            // A template that already existed on the YNAB side already has
            // an intentional splitwiseOption (even .never) — only adopt the
            // legacy value for a template that's new to the unified config.
            if isNewTemplate {
                template.splitwiseOption = legacyTemplate.splitOption
            }
            let existingPatterns = Set(template.autoMatch.map(\.pattern))
            for rule in legacyTemplate.autoMatch where !existingPatterns.contains(rule.pattern) {
                template.autoMatch.append(WalletTransactionConfig.AutoMatchRule(pattern: rule.pattern, payeeName: rule.expenseDescription))
            }
            merged.templates[name] = template
        }
        for (merchant, legacyInfo) in legacy.merchants where merged.merchants[merchant] == nil {
            merged.merchants[merchant] = WalletTransactionConfig.MerchantInfo(payeeName: legacyInfo.expenseDescription, templateName: legacyInfo.templateName)
        }

        let migratedURL = fileURL.deletingLastPathComponent().appendingPathComponent("splitwise-wallet-transaction-config.migrated.json")
        try? FileManager.default.removeItem(at: migratedURL)
        do {
            try FileManager.default.moveItem(at: fileURL, to: migratedURL)
        } catch {
            logger.error("failed to rename legacy config after merging — may re-merge next launch: \(String(describing: error), privacy: .public)")
        }
        logger.log("migrated legacy Splitwise config: \(legacy.templates.count, privacy: .public) templates, \(legacy.merchants.count, privacy: .public) merchants")
        return merged
    }
}
