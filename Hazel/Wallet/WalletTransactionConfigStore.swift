//
//  WalletTransactionConfigStore.swift
//  Hazel
//

import Foundation
import os

private let logger = Logger(subsystem: "com.pentlandFirth.Hazel", category: "WalletTransactionConfigStore")

enum WalletTransactionConfigStore {
    private static let fileURL = ApplicationSupportFile.url("wallet-transaction-config.json")

    static func load() -> WalletTransactionConfig {
        logger.log("loading config from \(fileURL.path, privacy: .public)")
        var config: WalletTransactionConfig
        if let data = try? Data(contentsOf: fileURL) {
            do {
                config = try JSONDecoder().decode(WalletTransactionConfig.self, from: data)
                logger.log("loaded config: \(config.merchants.count, privacy: .public) merchants, \(config.templates.count, privacy: .public) templates, \(config.cards.count, privacy: .public) cards")
            } catch {
                logger.error("failed to decode config, starting empty: \(String(describing: error), privacy: .public)")
                config = WalletTransactionConfig()
            }
        } else {
            logger.log("no existing config file — starting empty")
            config = WalletTransactionConfig()
        }

        if let migrated = LegacySplitwiseConfigMigration.mergeIfNeeded(into: config) {
            config = migrated
            try? save(config)
        }
        return config
    }

    static func save(_ config: WalletTransactionConfig) throws {
        let data = try JSONEncoder().encode(config)
        try data.write(to: fileURL, options: .atomic)
        logger.log("saved config to \(fileURL.path, privacy: .public)")
    }

    static func delete() throws {
        try FileManager.default.removeItem(at: fileURL)
        logger.log("deleted config at \(fileURL.path, privacy: .public)")
    }
}
