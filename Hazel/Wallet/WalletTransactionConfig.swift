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
//  A single template is shared by both AddWalletTransactionToYNABIntent and
//  AddWalletTransactionToSplitwiseIntent — the YNAB-specific fields
//  (categoryId) and Splitwise-specific fields (splitwiseOption/
//  splitwiseFriend*) simply go unused by whichever intent doesn't apply, and
//  the edit UI hides whichever half belongs to a disconnected provider.
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
        /// Mirrors the original shortcut's per-bucket "Use Splitwise?"
        /// choice, asked once during template setup and reused thereafter.
        /// `.ask` keeps prompting on every future transaction for this
        /// merchant, rather than fixing the answer forever.
        var splitwiseOption: SplitwiseTemplateOption = .never
        /// Optional, unlike AddWalletTransactionToSplitwiseIntent's original
        /// design where a template's friend was always set at creation time:
        /// once merged with YNAB templates (which never asked for a friend
        /// at all), a template can legitimately have none yet. Both intents
        /// treat a missing friend the same way — ask, same as before this
        /// field existed.
        var splitwiseFriendId: Int?
        var splitwiseFriendFirstName: String?
        var splitwiseFriendFullName: String?

        /// nil unless all three friend fields are set — a template can have
        /// some but not all filled in only via manual JSON edits, which this
        /// treats the same as "no cached friend, ask when needed."
        var splitwiseFriend: (id: Int, firstName: String, fullName: String)? {
            guard let id = splitwiseFriendId, let firstName = splitwiseFriendFirstName, let fullName = splitwiseFriendFullName else { return nil }
            return (id, firstName, fullName)
        }
    }

    struct AutoMatchRule: Codable, Equatable {
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
