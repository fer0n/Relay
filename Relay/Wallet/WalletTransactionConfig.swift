//
//  WalletTransactionConfig.swift
//  Relay
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

nonisolated struct WalletTransactionConfig: Codable {
    var merchants: [String: MerchantInfo] = [:]
    var templates: [String: Template] = [:]
    var cards: [String: String] = [:]

    init() {}

    /// Tolerant decoder, same rationale as `Template`'s: all three fields
    /// default to empty, so an older config written before one of them
    /// existed must fall back rather than throw. The synthesized decoder
    /// throws `keyNotFound` for a missing key even when the property has a
    /// default — and `WalletTransactionConfigStore.load()` turns any decode
    /// failure into a blank config, so a missing top-level key would wipe
    /// every saved merchant/template/card. This is the type most likely to
    /// gain new fields, so it's the one that most needs the guard.
    ///
    /// Declared in the primary body (not an extension like `Template`'s):
    /// for the top-level type an extension `init(from:)` does not displace
    /// the synthesized witness, so the tolerance was silently ignored. The
    /// explicit `init()` above keeps the empty-config initializer callers
    /// rely on, which declaring any initializer would otherwise suppress.
    /// `encode(to:)` stays synthesized, keeping the on-disk shape unchanged.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.merchants = try container.decodeIfPresent([String: MerchantInfo].self, forKey: .merchants) ?? [:]
        self.templates = try container.decodeIfPresent([String: Template].self, forKey: .templates) ?? [:]
        self.cards = try container.decodeIfPresent([String: String].self, forKey: .cards) ?? [:]
    }

    /// The three fields identifying a cached Splitwise friend, in the shape
    /// they're passed around in: `Template`'s stored friend, the value the
    /// intents resolve, and what `SplitwiseFriendEntity` mirrors. Named so
    /// the same tuple doesn't get re-spelled at every signature.
    typealias CachedFriend = (id: Int, firstName: String, fullName: String)

    /// Every field is required (no defaults), so the compiler-synthesized
    /// decoder is safe here — a missing key is a genuinely corrupt entry.
    /// If a *defaulted* field is ever added, give this the tolerant
    /// `init(from:)` treatment `Template` and `WalletTransactionConfig` use,
    /// or an older config missing the key wipes on load (see store).
    struct MerchantInfo: Codable {
        var payeeName: String
        var templateName: String
    }

    enum CodingKeys: String, CodingKey {
        case merchants, templates, cards
    }

    struct Template: Codable {
        var categoryId: String?
        /// Marks the single template that unknown Splitwise merchants are
        /// auto-filed under (see `ensureSplitwiseDefaultTemplate`). Tracked by
        /// this flag rather than a fixed name so the user can rename it — or
        /// create other templates and move merchants out — without breaking
        /// auto-filing. Exactly one template should ever carry it.
        ///
        /// A config written before this field existed has no key for it, so
        /// it MUST decode via the tolerant `init(from:)` below (which falls
        /// back to `false`). The synthesized decoder ignores this default
        /// value and would throw `keyNotFound` on an older config — wiping
        /// every template on load.
        var isSplitwiseDefault: Bool = false
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
        var splitwiseFriend: WalletTransactionConfig.CachedFriend? {
            guard let id = splitwiseFriendId, let firstName = splitwiseFriendFirstName, let fullName = splitwiseFriendFullName else { return nil }
            return (id, firstName, fullName)
        }

        /// Caches `friend` on this template unless it already has one — an
        /// existing cached friend is left untouched. Shared by both intent
        /// branches and `recordSplitwiseMerchantLink` so the "backfill a
        /// missing friend, never overwrite" rule lives in exactly one place.
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

    /// Both fields required, so the synthesized decoder is safe (see the
    /// note on `MerchantInfo`); switch to a tolerant `init(from:)` if a
    /// defaulted field is ever added here.
    struct AutoMatchRule: Codable, Equatable {
        var pattern: String
        var payeeName: String
    }

    /// The template new/unknown Splitwise merchants get auto-filed under, so
    /// the Splitwise wallet automation never has to walk the user through
    /// template setup — it just needs the split yes/no. Returns the existing
    /// default template's name if there is one, otherwise creates a fresh one
    /// (split option `.ask`, so every matching transaction still asks) and
    /// returns its name. Mutates `templates` when it creates one, so the
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

    /// Records a shortcut-started Splitwise submission's merchant mapping.
    /// Caches `friend` on the template when it has none yet (a freshly
    /// created default template, or an existing one that never had a friend;
    /// an existing cached friend is left untouched), and links — or re-links
    /// — the merchant to `templateName` under `payeeName` whenever that
    /// differs from what the merchant currently resolves to. That re-link is
    /// what makes editing the Payee field stick: next time this exact
    /// merchant resolves to the corrected name. A merchant that already
    /// resolves to exactly this payee+template (e.g. an unchanged auto-match
    /// rule shared by several merchants) is left alone rather than copied
    /// into a redundant per-merchant entry. Returns whether anything changed,
    /// so the caller can skip persisting an unchanged config.
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

    /// Links — or re-links — `merchant` to `templateName` under `payeeName`
    /// whenever that differs from what the merchant currently resolves to.
    /// Shared by the YNAB and Splitwise submit paths so editing the Payee
    /// field is applied automatically next time. A merchant that already
    /// resolves to exactly this payee+template (e.g. an unchanged auto-match
    /// rule shared by several merchants) is left alone rather than copied into
    /// a redundant per-merchant entry. Returns whether the mapping changed.
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

    /// The template a *already-created* transaction was filed under, worked
    /// backwards from what got stored with it. TransactionHistoryEntry
    /// records the transaction, not the template behind it, so "Re-add" has
    /// to invert the same mappings that produced the payee in the first
    /// place — in the order resolution originally ran:
    ///
    /// 1. the merchant's own mapping, when the run recorded a merchant
    ///    (`TransactionHistoryEntry.merchant`) — the exact lookup the
    ///    original submit did;
    /// 2. whichever per-merchant mapping or auto-match rule *names* this
    ///    payee, since that name is precisely what such a rule emits;
    /// 3. a template named after the payee, which is what the manual
    ///    Splitwise submit path creates when no template is picked.
    ///
    /// Nil when the payee was typed freehand and never linked to anything,
    /// and for a mapping pointing at a since-deleted template — the picker
    /// then opens unset rather than on a name it can't offer. Resolving
    /// against the *current* config (rather than a name frozen into the
    /// history entry) also means a template renamed since still resolves.
    func templateName(forPayeeName payeeName: String, merchant: String?) -> String? {
        if let merchant, let info = resolvedMerchantInfo(for: merchant), templates[info.templateName] != nil {
            return info.templateName
        }
        // Sorted rather than straight dictionary iteration so an ambiguous
        // config (the same payee named by two templates) resolves to the
        // same one every time instead of varying per launch.
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
    /// Tolerant decoder: every field falls back to its default when the key
    /// is absent, so adding a new stored property never invalidates configs
    /// written by an older build. The compiler-synthesized decoder does NOT
    /// use property default values — it throws `keyNotFound` for any missing
    /// non-optional key — which, since one failed template decode fails the
    /// whole `WalletTransactionConfig`, would silently wipe every template,
    /// merchant, and card mapping on the next load. Declared in an extension
    /// so the memberwise initializer stays synthesized; `encode(to:)` stays
    /// synthesized too, keeping the on-disk shape unchanged.
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
