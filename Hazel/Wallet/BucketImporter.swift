//
//  BucketImporter.swift
//  Hazel
//
//  Translates a decoded BucketImportFile into WalletTransactionConfig.
//  Buckets map onto templates and merchants map onto merchants directly;
//  each bucket's category name is resolved against the caller's YNAB
//  category list since the config store keys categories by id, not name.
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
}
