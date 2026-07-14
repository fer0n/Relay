//
//  SplitwiseWalletTransactionConfig.swift
//  Hazel
//
//  Backs AddWalletTransactionToSplitwiseIntent — a Wallet-triggered
//  automation that creates a Splitwise expense directly, with no YNAB
//  transaction involved. Mirrors WalletTransactionConfig.swift's
//  template/merchant shape, but a template holds a Splitwise friend +
//  split mode instead of a YNAB category/account, and there's no `cards`
//  map since Splitwise has no "account" concept to map a card to.
//

import Foundation

struct SplitwiseWalletTransactionConfig: Codable {
    var merchants: [String: MerchantInfo] = [:]
    var templates: [String: Template] = [:]

    struct MerchantInfo: Codable {
        var expenseDescription: String
        var templateName: String
    }

    struct Template: Codable {
        var friendId: Int
        /// Denormalized alongside `friendId` so perform() can build a
        /// SplitwiseFriendEntity for SplitwiseExpenseHelper without an
        /// extra fetchFriends call on every cached-template run.
        var friendFirstName: String
        var friendFullName: String
        var splitOption: SplitwiseTemplateOption = .never
        var autoMatch: [AutoMatchRule] = []
    }

    struct AutoMatchRule: Codable {
        var pattern: String
        var expenseDescription: String
    }

    func resolvedMerchantInfo(for merchantText: String) -> MerchantInfo? {
        if let info = merchants[merchantText] {
            return info
        }
        for (templateName, template) in templates {
            for rule in template.autoMatch {
                if merchantText.range(of: rule.pattern, options: [.regularExpression, .caseInsensitive]) != nil {
                    return MerchantInfo(expenseDescription: rule.expenseDescription, templateName: templateName)
                }
            }
        }
        return nil
    }
}
