//
//  WalletTransactionConfigTemplateLookupTests.swift
//  RelayTests
//
//  Covers WalletTransactionConfig.templateName(forPayeeName:merchant:) — the
//  reverse lookup behind "Re-add" prefilling the Template row. History
//  entries record the created transaction, not the template it was filed
//  under, so the template has to be worked backwards out of the merchant and
//  payee mappings that produced it.
//

import Foundation
import Testing
@testable import Relay

@MainActor
struct WalletTransactionConfigTemplateLookupTests {
    private static func template(rules: [WalletTransactionConfig.AutoMatchRule] = []) -> WalletTransactionConfig.Template {
        var t = WalletTransactionConfig.Template()
        t.autoMatch = rules
        return t
    }

    @Test
    func recordedMerchantResolvesThroughItsOwnMapping() {
        var config = WalletTransactionConfig()
        config.templates["Groceries"] = Self.template()
        config.merchants["REWE SAGT DANKE"] = .init(payeeName: "Rewe", templateName: "Groceries")

        #expect(config.templateName(forPayeeName: "Rewe", merchant: "REWE SAGT DANKE") == "Groceries")
    }

    @Test
    func recordedMerchantResolvesThroughAnAutoMatchRule() {
        var config = WalletTransactionConfig()
        config.templates["Groceries"] = Self.template(rules: [.init(pattern: "REWE.*", payeeName: "Rewe")])

        #expect(config.templateName(forPayeeName: "Rewe", merchant: "REWE SAGT DANKE") == "Groceries")
    }

    /// The YNAB write path doesn't record a merchant, so the payee name is
    /// all a re-add has to go on — it still names exactly one template.
    @Test
    func payeeNameAloneResolvesThroughAPerMerchantMapping() {
        var config = WalletTransactionConfig()
        config.templates["Groceries"] = Self.template()
        config.merchants["REWE SAGT DANKE"] = .init(payeeName: "Rewe", templateName: "Groceries")

        #expect(config.templateName(forPayeeName: "Rewe", merchant: nil) == "Groceries")
    }

    @Test
    func payeeNameAloneResolvesThroughAnAutoMatchRule() {
        var config = WalletTransactionConfig()
        config.templates["Groceries"] = Self.template(rules: [.init(pattern: "REWE.*", payeeName: "Rewe")])

        #expect(config.templateName(forPayeeName: "Rewe", merchant: nil) == "Groceries")
    }

    /// What the manual Splitwise submit path leaves behind when no template
    /// was picked: a template named after the payee, with no rule at all.
    @Test
    func templateNamedAfterThePayeeResolves() {
        var config = WalletTransactionConfig()
        config.templates["Rewe"] = Self.template()

        #expect(config.templateName(forPayeeName: "Rewe", merchant: nil) == "Rewe")
    }

    @Test
    func freehandPayeeResolvesToNothing() {
        var config = WalletTransactionConfig()
        config.templates["Groceries"] = Self.template(rules: [.init(pattern: "REWE.*", payeeName: "Rewe")])

        #expect(config.templateName(forPayeeName: "Some Corner Shop", merchant: nil) == nil)
    }

    /// A mapping left pointing at a template the user has since deleted must
    /// not select a name the picker can't offer.
    @Test
    func mappingToADeletedTemplateResolvesToNothing() {
        var config = WalletTransactionConfig()
        config.merchants["REWE SAGT DANKE"] = .init(payeeName: "Rewe", templateName: "Deleted")

        #expect(config.templateName(forPayeeName: "Rewe", merchant: "REWE SAGT DANKE") == nil)
        #expect(config.templateName(forPayeeName: "Rewe", merchant: nil) == nil)
    }

    /// The merchant's own mapping wins over any other template that happens
    /// to name the same payee — it's the lookup the original submit did.
    @Test
    func recordedMerchantWinsOverAnotherTemplateNamingTheSamePayee() {
        var config = WalletTransactionConfig()
        config.templates["Groceries"] = Self.template()
        config.templates["Rewe"] = Self.template(rules: [.init(pattern: "REWE.*", payeeName: "Rewe")])
        config.merchants["REWE SAGT DANKE"] = .init(payeeName: "Rewe", templateName: "Groceries")

        #expect(config.templateName(forPayeeName: "Rewe", merchant: "REWE SAGT DANKE") == "Groceries")
    }

    /// An ambiguous config resolves to the same template every time rather
    /// than varying with dictionary iteration order.
    @Test
    func ambiguousPayeeResolvesDeterministically() {
        var config = WalletTransactionConfig()
        config.templates["Alpha"] = Self.template(rules: [.init(pattern: "REWE.*", payeeName: "Rewe")])
        config.templates["Beta"] = Self.template(rules: [.init(pattern: "REWE.*", payeeName: "Rewe")])

        for _ in 0..<20 {
            #expect(config.templateName(forPayeeName: "Rewe", merchant: nil) == "Alpha")
        }
    }
}
