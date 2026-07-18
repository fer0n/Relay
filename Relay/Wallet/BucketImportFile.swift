//
//  BucketImportFile.swift
//  Relay
//
//  Decodes the JSON export produced by the original "Transaction → YNAB"
//  Shortcut's DataJar (buckets/merchants/cards), so that data can be
//  migrated into WalletTransactionConfig without re-entering it by hand.
//

import Foundation

struct BucketImportFile: Codable {
    struct AutoMatch: Codable {
        var match: String
        var name: String
    }

    struct Bucket: Codable {
        var category: String?
        var autoMatch: [AutoMatch] = []
        var splitwise: SplitwiseTemplateOption = .never
    }

    struct Merchant: Codable {
        var name: String
        var bucket: String
    }

    var buckets: [String: Bucket] = [:]
    var merchants: [String: Merchant] = [:]
    /// Raw bank card name → short display name. Relay's own `cards` map
    /// stores a YNAB account id instead (resolved interactively the first
    /// time a card is seen), so there's nowhere to put this on import — see
    /// BucketImporter.merge(_:into:categories:).
    var cards: [String: String] = [:]
}
