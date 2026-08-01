//
//  WalletTransactionConfig.swift
//  Relay
//
//  Replaces the "Transaction → YNAB" Shortcut's DataJar-backed config. A
//  template groups a category with auto-match rules, each pairing a
//  merchant-matching pattern with the payee name to use for it — so several
//  merchants (different Amazon storefronts, say) can share one template while
//  still resolving to distinct payee names.
//
//  Both wallet intents share one template type; the fields belonging to the
//  other service simply go unused, and the edit UI hides whichever half
//  belongs to a disconnected provider.
//

import Foundation

nonisolated struct WalletTransactionConfig: Codable {
    var merchants: [String: MerchantInfo] = [:]
    var templates: [String: Template] = [:]
    var cards: [String: String] = [:]

    init() {}

    /// Tolerant decoder, same rationale as `Template`'s. Declared in the primary
    /// body rather than an extension: for the top-level type an extension
    /// `init(from:)` doesn't displace the synthesized witness, so the tolerance
    /// was silently ignored.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.merchants = try container.decodeIfPresent([String: MerchantInfo].self, forKey: .merchants) ?? [:]
        self.templates = try container.decodeIfPresent([String: Template].self, forKey: .templates) ?? [:]
        self.cards = try container.decodeIfPresent([String: String].self, forKey: .cards) ?? [:]
    }

    typealias CachedFriend = (id: Int, firstName: String, fullName: String)

    /// No defaulted fields, so the synthesized decoder is safe — a missing key is
    /// a genuinely corrupt entry. Adding a defaulted field means giving this the
    /// tolerant `init(from:)` treatment too.
    struct MerchantInfo: Codable {
        var payeeName: String
        var templateName: String
    }

    enum CodingKeys: String, CodingKey {
        case merchants, templates, cards
    }

    struct Template: Codable {
        var categoryId: String?
        /// Marks the single template unknown Splitwise merchants are auto-filed
        /// under (see `ensureSplitwiseDefaultTemplate`). A flag rather than a
        /// fixed name so the user can rename it without breaking auto-filing.
        var isSplitwiseDefault: Bool = false
        var autoMatch: [AutoMatchRule] = []
        /// `.ask` keeps prompting on every future transaction for this merchant
        /// rather than fixing the answer forever.
        var splitwiseOption: SplitwiseTemplateOption = .never
        var splitwiseFriendId: Int?
        var splitwiseFriendFirstName: String?
        var splitwiseFriendFullName: String?

        /// nil unless all three fields are set — a partial friend is only
        /// reachable via manual JSON edits, and means "ask when needed" too.
        var splitwiseFriend: WalletTransactionConfig.CachedFriend? {
            guard let id = splitwiseFriendId, let firstName = splitwiseFriendFirstName, let fullName = splitwiseFriendFullName else { return nil }
            return (id, firstName, fullName)
        }

        /// Returns whether it wrote anything, so callers can track `changed`.
        mutating func cacheSplitwiseFriendIfMissing(_ friend: WalletTransactionConfig.CachedFriend) -> Bool {
            guard splitwiseFriend == nil else { return false }
            splitwiseFriendId = friend.id
            splitwiseFriendFirstName = friend.firstName
            splitwiseFriendFullName = friend.fullName
            return true
        }

        enum CodingKeys: String, CodingKey {
            case categoryId, isSplitwiseDefault, autoMatch, splitwiseOption
            case splitwiseFriendId, splitwiseFriendFirstName, splitwiseFriendFullName
        }
    }

    /// Synthesized decoder is safe — see the note on `MerchantInfo`.
    struct AutoMatchRule: Codable, Equatable {
        var pattern: String
        var payeeName: String
    }

    /// The template unknown Splitwise merchants get auto-filed under, so that
    /// automation never has to walk the user through template setup — it just
    /// needs the split yes/no. Mutates `templates` when it creates one, so the
    /// caller must persist `self` afterwards.
    mutating func ensureSplitwiseDefaultTemplate() -> String {
        if let existing = templates.first(where: { $0.value.isSplitwiseDefault }) {
            return existing.key
        }
        let baseName = String(localized: "Shared Expenses")
        var name = baseName
        var suffix = 2
        while templates[name] != nil {
            name = "\(baseName) \(suffix)"
            suffix += 1
        }
        var template = Template()
        template.isSplitwiseDefault = true
        template.splitwiseOption = .ask
        templates[name] = template
        return name
    }

    /// Returns whether anything changed, so the caller can skip persisting an
    /// unchanged config.
    mutating func recordSplitwiseMerchantLink(
        merchant: String,
        payeeName: String,
        templateName: String,
        friend: CachedFriend
    ) -> Bool {
        var changed = false
        var template = templates[templateName] ?? Template()
        if template.cacheSplitwiseFriendIfMissing(friend) {
            templates[templateName] = template
            changed = true
        }
        if linkMerchantIfChanged(merchant: merchant, payeeName: payeeName, templateName: templateName) {
            changed = true
        }
        return changed
    }

    /// Re-links `merchant` whenever it resolves to something other than
    /// `payeeName`+`templateName`, which is what makes editing the Payee field
    /// stick. A merchant already resolving to exactly this — via a shared
    /// auto-match rule, say — is left alone rather than copied into a redundant
    /// per-merchant entry. Returns whether the mapping changed.
    mutating func linkMerchantIfChanged(merchant: String, payeeName: String, templateName: String) -> Bool {
        let resolved = resolvedMerchantInfo(for: merchant)
        guard resolved?.payeeName != payeeName || resolved?.templateName != templateName else { return false }
        merchants[merchant] = MerchantInfo(payeeName: payeeName, templateName: templateName)
        return true
    }

    func resolvedMerchantInfo(for merchantText: String) -> MerchantInfo? {
        if let info = merchants[merchantText] {
            return info
        }
        for templateName in templates.keys.sorted() {
            for rule in templates[templateName]?.autoMatch ?? [] {
                if merchantText.range(of: rule.pattern, options: [.regularExpression, .caseInsensitive]) != nil {
                    return MerchantInfo(payeeName: rule.payeeName, templateName: templateName)
                }
            }
        }
        return nil
    }

    /// The template an already-created transaction was filed under. A history
    /// entry records the transaction, not its template, so "Re-add" inverts the
    /// mappings that produced the payee, in the order resolution originally ran:
    /// the merchant's own mapping, then whichever mapping or auto-match rule
    /// *names* this payee, then a template named after the payee (what the manual
    /// Splitwise path creates).
    ///
    /// Nil for a freehand payee and for a mapping pointing at a deleted
    /// template, so the picker opens unset rather than on a name it can't offer.
    /// Resolving against the current config also means a renamed template still
    /// resolves.
    func templateName(forPayeeName payeeName: String, merchant: String?) -> String? {
        if let merchant, let info = resolvedMerchantInfo(for: merchant), templates[info.templateName] != nil {
            return info.templateName
        }
        // Sorted so an ambiguous config (the same payee named by two templates)
        // resolves the same way every launch.
        for merchantText in merchants.keys.sorted() {
            guard let info = merchants[merchantText], info.payeeName == payeeName else { continue }
            if templates[info.templateName] != nil { return info.templateName }
        }
        for templateName in templates.keys.sorted() where templates[templateName]?.autoMatch.contains(where: { $0.payeeName == payeeName }) == true {
            return templateName
        }
        return templates[payeeName] != nil ? payeeName : nil
    }
}

nonisolated extension WalletTransactionConfig.Template {
    /// Tolerant decoder, so adding a stored property never invalidates configs
    /// written by an older build. The synthesized decoder ignores property
    /// defaults and throws `keyNotFound` for any missing non-optional key —
    /// which, since one failed template decode fails the whole config, would
    /// wipe every template, merchant, and card mapping on the next load.
    /// In an extension so the memberwise init and `encode(to:)` stay synthesized.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.categoryId = try container.decodeIfPresent(String.self, forKey: .categoryId)
        self.isSplitwiseDefault = try container.decodeIfPresent(Bool.self, forKey: .isSplitwiseDefault) ?? false
        self.autoMatch = try container.decodeIfPresent([WalletTransactionConfig.AutoMatchRule].self, forKey: .autoMatch) ?? []
        self.splitwiseOption = try container.decodeIfPresent(SplitwiseTemplateOption.self, forKey: .splitwiseOption) ?? .never
        self.splitwiseFriendId = try container.decodeIfPresent(Int.self, forKey: .splitwiseFriendId)
        self.splitwiseFriendFirstName = try container.decodeIfPresent(String.self, forKey: .splitwiseFriendFirstName)
        self.splitwiseFriendFullName = try container.decodeIfPresent(String.self, forKey: .splitwiseFriendFullName)
    }
}
