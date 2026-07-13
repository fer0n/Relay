//
//  WalletTransactionConfig.swift
//  Hazel
//
//  Replaces the "Transaction → YNAB" Shortcut's DataJar-backed config. A
//  template groups a category with a set of auto-match rules; each rule
//  pairs a merchant-matching pattern with the payee name to use for it, so
//  multiple merchants (e.g. different Amazon storefronts) can share one
//  template/category while still resolving to distinct payee names.
//  Cards map to a YNAB account so recurring cards don't need re-asking.
//

import Foundation

struct WalletTransactionConfig: Codable {
    var merchants: [String: MerchantInfo] = [:]
    var templates: [String: Template] = [:]
    var cards: [String: String] = [:]

    struct MerchantInfo: Codable {
        var payeeName: String
        var templateName: String
    }

    struct Template: Codable {
        var categoryId: String?
        var autoMatch: [AutoMatchRule] = []
    }

    struct AutoMatchRule: Codable {
        var pattern: String
        var payeeName: String
    }

    func resolvedMerchantInfo(for merchantText: String) -> MerchantInfo? {
        if let info = merchants[merchantText] {
            return info
        }
        for (templateName, template) in templates {
            for rule in template.autoMatch {
                if merchantText.range(of: rule.pattern, options: [.regularExpression, .caseInsensitive]) != nil {
                    return MerchantInfo(payeeName: rule.payeeName, templateName: templateName)
                }
            }
        }
        return nil
    }
}
