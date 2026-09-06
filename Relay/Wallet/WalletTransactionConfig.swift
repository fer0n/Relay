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

    /// The one split target a template remembers: a whole ledger, or one
    /// person on it. `participantID` nil means everyone on the ledger, the
    /// same convention `SplitTargetEntity` uses.
    struct CachedSplitTarget: Equatable {
        var zoneName: String
        var participantID: String?
        var firstName: String
        var fullName: String

        init(zoneName: String, participantID: String?, firstName: String, fullName: String) {
            self.zoneName = zoneName
            self.participantID = participantID
            self.firstName = firstName
            self.fullName = fullName
        }

        /// Everyone on the ledger.
        init(ledger: Ledger) {
            self.init(
                zoneName: ledger.zoneName,
                participantID: nil,
                firstName: ledger.name,
                fullName: ledger.name
            )
        }

        init(ledger: Ledger, participant: LedgerParticipant) {
            self.init(
                zoneName: ledger.zoneName,
                participantID: participant.id,
                firstName: participant.firstName,
                fullName: participant.displayName
            )
        }
    }

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
        /// Marks the single template unknown split merchants are auto-filed
        /// under (see `ensureSplitDefaultTemplate`). A flag rather than a
        /// fixed name so the user can rename it without breaking auto-filing.
        var isSplitDefault: Bool = false
        var autoMatch: [AutoMatchRule] = []
        /// `.ask` keeps prompting on every future transaction for this merchant
        /// rather than fixing the answer forever.
        var splitOption: SplitTemplateOption = .never
        var ledgerZoneName: String?
        /// nil with a `ledgerZoneName` set means everyone on the ledger.
        var ledgerParticipantID: String?
        var splitTargetFirstName: String?
        var splitTargetFullName: String?

        /// nil unless the ledger and both names are set — a partial target is
        /// only reachable via manual JSON edits, and means "ask when needed" too.
        var splitTarget: WalletTransactionConfig.CachedSplitTarget? {
            guard let ledgerZoneName,
                  let firstName = splitTargetFirstName,
                  let fullName = splitTargetFullName else { return nil }
            return WalletTransactionConfig.CachedSplitTarget(
                zoneName: ledgerZoneName,
                participantID: ledgerParticipantID,
                firstName: firstName,
                fullName: fullName
            )
        }

        /// Returns whether it wrote anything, so callers can track `changed`.
        mutating func cacheSplitTargetIfMissing(_ target: WalletTransactionConfig.CachedSplitTarget) -> Bool {
            guard splitTarget == nil else { return false }
            ledgerZoneName = target.zoneName
            ledgerParticipantID = target.participantID
            splitTargetFirstName = target.firstName
            splitTargetFullName = target.fullName
            return true
        }

        enum CodingKeys: String, CodingKey {
            case categoryId, autoMatch
            // Kept at their old spellings so a config written before Splitwise
            // was removed keeps its per-template split setting and its
            // auto-file flag; only the target itself was Splitwise-shaped and
            // is cleared by SplitwiseRemovalMigration.
            // These two raw values must stay at their old Splitwise spellings:
            // they're what's on disk in every config written before the
            // removal, and a rename here silently resets each template's split
            // setting to `.never` and forgets which one merchants auto-file
            // under. Only the *target* was Splitwise-shaped; the setting itself
            // is still meaningful and is deliberately preserved.
            case isSplitDefault = "isSplitwiseDefault"
            case splitOption = "splitwiseOption"
            case ledgerZoneName, ledgerParticipantID, splitTargetFirstName, splitTargetFullName
        }
    }

    /// Synthesized decoder is safe — see the note on `MerchantInfo`.
    struct AutoMatchRule: Codable, Equatable {
        var pattern: String
        var payeeName: String
    }

    /// The template unknown split merchants get auto-filed under, so that
    /// automation never has to walk the user through template setup — it just
    /// needs the split yes/no. Mutates `templates` when it creates one, so the
    /// caller must persist `self` afterwards.
    mutating func ensureSplitDefaultTemplate() -> String {
        if let existing = templates.first(where: { $0.value.isSplitDefault }) {
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
        template.isSplitDefault = true
        template.splitOption = .ask
        templates[name] = template
        return name
    }

    /// Returns whether anything changed, so the caller can skip persisting an
    /// unchanged config.
    mutating func recordSplitMerchantLink(
        merchant: String,
        payeeName: String,
        templateName: String,
        target: CachedSplitTarget
    ) -> Bool {
        var changed = false
        var template = templates[templateName] ?? Template()
        if template.cacheSplitTargetIfMissing(target) {
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
    /// split path creates).
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
        self.isSplitDefault = try container.decodeIfPresent(Bool.self, forKey: .isSplitDefault) ?? false
        self.autoMatch = try container.decodeIfPresent([WalletTransactionConfig.AutoMatchRule].self, forKey: .autoMatch) ?? []
        self.splitOption = try container.decodeIfPresent(SplitTemplateOption.self, forKey: .splitOption) ?? .never
        self.splitTargetFirstName = try container.decodeIfPresent(String.self, forKey: .splitTargetFirstName)
        self.splitTargetFullName = try container.decodeIfPresent(String.self, forKey: .splitTargetFullName)
        self.ledgerZoneName = try container.decodeIfPresent(String.self, forKey: .ledgerZoneName)
        self.ledgerParticipantID = try container.decodeIfPresent(String.self, forKey: .ledgerParticipantID)
    }
}
