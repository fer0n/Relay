//
//  BucketImporter.swift
//  Relay
//
//  Merges externally-sourced template data into WalletTransactionConfig.
//  `merge(_:into:categories:)` translates a decoded BucketImportFile (the
//  legacy "YNAB Toolkit" Shortcut's DataJar export) — buckets map onto
//  templates and merchants map onto merchants, with each bucket's category
//  name resolved against the caller's YNAB category list since the config
//  store keys categories by id, not name. `mergeNative(_:into:)` instead
//  merges Relay's own full-fidelity export format, which needs no
//  translation since it's already in the store's own shape.
//

import Foundation

enum BucketImporter {
    struct Result {
        var importedBucketCount: Int
        var importedMerchantCount: Int
        var unresolvedCategoryNames: [String]
        var skippedCardCount: Int
    }

    static func merge(_ file: BucketImportFile, into config: inout WalletTransactionConfig, categories: [YNABCategory]) -> Result {
        var unresolvedCategoryNames: [String] = []

        for (bucketName, bucket) in file.buckets {
            var categoryId: String?
            if let categoryName = bucket.category {
                if let match = categories.first(where: { $0.name.caseInsensitiveCompare(categoryName) == .orderedSame }) {
                    categoryId = match.id
                } else {
                    unresolvedCategoryNames.append(categoryName)
                }
            }
            config.templates[bucketName] = WalletTransactionConfig.Template(
                categoryId: categoryId,
                autoMatch: bucket.autoMatch.map { WalletTransactionConfig.AutoMatchRule(pattern: $0.match, payeeName: $0.name) },
                splitwiseOption: bucket.splitwise
            )
        }

        for (merchantName, merchant) in file.merchants {
            config.merchants[merchantName] = WalletTransactionConfig.MerchantInfo(
                payeeName: merchant.name,
                templateName: merchant.bucket
            )
        }

        return Result(
            importedBucketCount: file.buckets.count,
            importedMerchantCount: file.merchants.count,
            unresolvedCategoryNames: Array(Set(unresolvedCategoryNames)).sorted(),
            skippedCardCount: file.cards.count
        )
    }

    struct NativeMergeResult {
        var importedTemplateCount: Int
        var importedMerchantCount: Int
        var importedCardCount: Int
    }

    /// Merges a full WalletTransactionConfig export (Relay's own native
    /// format, produced by Settings' "Export Templates") directly — unlike
    /// `merge(_:into:categories:)`, there's no category-name resolution or
    /// field translation needed since it's already in the store's own
    /// shape, id for id.
    static func mergeNative(_ export: WalletTransactionConfig, into config: inout WalletTransactionConfig) -> NativeMergeResult {
        for (name, template) in export.templates {
            config.templates[name] = template
        }
        for (merchant, info) in export.merchants {
            config.merchants[merchant] = info
        }
        for (card, accountId) in export.cards {
            config.cards[card] = accountId
        }
        return NativeMergeResult(
            importedTemplateCount: export.templates.count,
            importedMerchantCount: export.merchants.count,
            importedCardCount: export.cards.count
        )
    }
}
