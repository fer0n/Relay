//
//  WalletTransactionConfigLinkTests.swift
//  RelayTests
//
//  Covers WalletTransactionConfig.recordSplitMerchantLink — the logic
//  that makes editing a Splitwise draft's Payee field stick: the merchant is
//  (re)linked to its template under the corrected name so it resolves
//  correctly next time, without duplicating unchanged auto-matches into
//  redundant per-merchant entries.
//

import Foundation
import Testing
@testable import Relay

@MainActor
struct WalletTransactionConfigLinkTests {
    private static let friend = WalletTransactionConfig.CachedSplitTarget(zoneName: "Ledger-test", participantID: "p7", firstName: "Sam", fullName: "Sam Rivera")

    private static func template(withFriend: Bool = false, rules: [WalletTransactionConfig.AutoMatchRule] = []) -> WalletTransactionConfig.Template {
        var t = WalletTransactionConfig.Template()
        t.autoMatch = rules
        if withFriend {
            t.ledgerZoneName = "Ledger-test"
            t.ledgerParticipantID = "p7"
            t.splitTargetFirstName = "Sam"
            t.splitTargetFullName = "Sam Rivera"
        }
        return t
    }

    @Test
    func newMerchantIsLinkedAndFriendCached() {
        var config = WalletTransactionConfig()
        config.templates["Shared"] = Self.template()

        let changed = config.recordSplitMerchantLink(
            merchant: "REWE SAGT DANKE", payeeName: "Rewe", templateName: "Shared", target: Self.friend
        )

        #expect(changed)
        #expect(config.merchants["REWE SAGT DANKE"]?.payeeName == "Rewe")
        #expect(config.merchants["REWE SAGT DANKE"]?.templateName == "Shared")
        #expect(config.templates["Shared"]?.splitTarget?.participantID == "p7")
    }

    @Test
    func editingPayeeUpdatesTheStoredMappingName() {
        var config = WalletTransactionConfig()
        config.templates["Shared"] = Self.template(withFriend: true)
        config.merchants["REWE SAGT DANKE"] = .init(payeeName: "Old Name", templateName: "Shared")

        let changed = config.recordSplitMerchantLink(
            merchant: "REWE SAGT DANKE", payeeName: "Rewe", templateName: "Shared", target: WalletTransactionConfig.CachedSplitTarget(zoneName: "Ledger-test", participantID: "p9", firstName: "Alex", fullName: "Alex Kim")
        )

        #expect(changed)
        #expect(config.merchants["REWE SAGT DANKE"]?.payeeName == "Rewe")
        // The template already had a friend, so it's left untouched.
        #expect(config.templates["Shared"]?.splitTarget?.participantID == "p7")
    }

    @Test
    func unchangedExactMappingIsLeftAlone() {
        var config = WalletTransactionConfig()
        config.templates["Shared"] = Self.template(withFriend: true)
        config.merchants["REWE SAGT DANKE"] = .init(payeeName: "Rewe", templateName: "Shared")

        let changed = config.recordSplitMerchantLink(
            merchant: "REWE SAGT DANKE", payeeName: "Rewe", templateName: "Shared", target: Self.friend
        )

        #expect(!changed)
    }

    @Test
    func unchangedAutoMatchIsNotDuplicatedIntoAPerMerchantEntry() {
        var config = WalletTransactionConfig()
        config.templates["Shared"] = Self.template(withFriend: true, rules: [.init(pattern: "REWE.*", payeeName: "Rewe")])

        // "REWE SAGT DANKE" already resolves to (Rewe, Shared) via the rule.
        let changed = config.recordSplitMerchantLink(
            merchant: "REWE SAGT DANKE", payeeName: "Rewe", templateName: "Shared", target: Self.friend
        )

        #expect(!changed)
        #expect(config.merchants["REWE SAGT DANKE"] == nil)
    }

    @Test
    func editingAnAutoMatchedMerchantWritesAnExactOverride() {
        var config = WalletTransactionConfig()
        config.templates["Shared"] = Self.template(withFriend: true, rules: [.init(pattern: "REWE.*", payeeName: "Rewe")])

        let changed = config.recordSplitMerchantLink(
            merchant: "REWE SAGT DANKE", payeeName: "Rewe Berlin", templateName: "Shared", target: Self.friend
        )

        #expect(changed)
        #expect(config.merchants["REWE SAGT DANKE"]?.payeeName == "Rewe Berlin")
        // The shared rule is untouched; the exact entry now wins resolution.
        #expect(config.templates["Shared"]?.autoMatch == [.init(pattern: "REWE.*", payeeName: "Rewe")])
        #expect(config.resolvedMerchantInfo(for: "REWE SAGT DANKE")?.payeeName == "Rewe Berlin")
    }

    @Test
    func friendIsCachedOnATemplateThatHasNoneYet() {
        var config = WalletTransactionConfig()
        config.templates["Shared"] = Self.template(withFriend: false)
        config.merchants["REWE SAGT DANKE"] = .init(payeeName: "Rewe", templateName: "Shared")

        // Mapping name unchanged, but the template gains its first friend.
        let changed = config.recordSplitMerchantLink(
            merchant: "REWE SAGT DANKE", payeeName: "Rewe", templateName: "Shared", target: Self.friend
        )

        #expect(changed)
        #expect(config.templates["Shared"]?.splitTarget?.participantID == "p7")
    }
}
