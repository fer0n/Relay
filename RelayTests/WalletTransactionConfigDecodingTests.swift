//
//  WalletTransactionConfigDecodingTests.swift
//  RelayTests
//
//  Regression coverage for the data-loss bug where adding a new non-optional
//  stored property (`isSplitDefault`) to WalletTransactionConfig.Template
//  made every config written by an older build fail to decode — the
//  compiler-synthesized decoder throws `keyNotFound` for a missing key rather
//  than using the property's default value, and one failed Template decode
//  fails the whole config, wiping every template/merchant/card on load. The
//  tolerant `init(from:)` on Template is what these guard.
//

import Foundation
import Testing
@testable import Relay

@MainActor
struct WalletTransactionConfigDecodingTests {
    /// A config exactly as an older build would have written it: no
    /// `isSplitwiseDefault` key anywhere, and a Splitwise friend as the
    /// template's split target. Both the missing key and the now-unreadable
    /// target have to leave the rest of the config intact.
    private static let legacyJSON = """
    {
      "merchants": {
        "REWE SAGT DANKE": { "payeeName": "Rewe", "templateName": "Groceries" }
      },
      "templates": {
        "Groceries": {
          "autoMatch": [ { "pattern": "REWE.*", "payeeName": "Rewe" } ],
          "splitwiseOption": "ask",
          "splitwiseFriendId": 42,
          "splitwiseFriendFirstName": "Sam",
          "splitwiseFriendFullName": "Sam Rivera"
        }
      },
      "cards": { "Visa": "acct-1" }
    }
    """

    @Test
    func decodesConfigWrittenBeforeIsSplitDefaultExisted() throws {
        let config = try JSONDecoder().decode(WalletTransactionConfig.self, from: Data(Self.legacyJSON.utf8))

        // The whole point: a missing new key must not wipe existing data.
        #expect(config.templates.count == 1)
        #expect(config.merchants.count == 1)
        #expect(config.cards["Visa"] == "acct-1")

        let template = try #require(config.templates["Groceries"])
        #expect(template.isSplitDefault == false)
        #expect(template.splitOption == .ask)
        #expect(template.autoMatch == [.init(pattern: "REWE.*", payeeName: "Rewe")])
        // The Splitwise target is deliberately *not* carried over: it named a
        // Splitwise friend by integer id, which nothing can resolve now. The
        // template itself survives — its category, rules and split option are
        // what took months to build up — and the user re-picks who to split
        // with. See SplitwiseRemovalMigration.
        #expect(template.splitTarget == nil)
    }

    @Test
    func ensureSplitDefaultTemplateCreatesAskTemplateAndIsIdempotent() {
        var config = WalletTransactionConfig()

        let name = config.ensureSplitDefaultTemplate()
        #expect(config.templates[name]?.isSplitDefault == true)
        #expect(config.templates[name]?.splitOption == .ask)

        // A second call returns the same template rather than adding another.
        let again = config.ensureSplitDefaultTemplate()
        #expect(again == name)
        #expect(config.templates.count == 1)
    }

    @Test
    func isSplitDefaultSurvivesEncodeDecodeRoundTrip() throws {
        var config = WalletTransactionConfig()
        _ = config.ensureSplitDefaultTemplate()

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(WalletTransactionConfig.self, from: data)

        #expect(decoded.templates.values.filter(\.isSplitDefault).count == 1)
    }

    /// The same tolerant-decoder guard applied to the top-level config: a
    /// config written before one of its dictionaries existed (here `cards`)
    /// must still decode, keeping the other maps, rather than throwing
    /// `keyNotFound` and wiping everything. Regression coverage for the
    /// most likely place a new field gets added.
    @Test
    func decodesTopLevelConfigMissingAKey() throws {
        let json = """
        {
          "templates": {
            "Groceries": { "autoMatch": [], "splitOption": "never" }
          }
        }
        """
        let config = try JSONDecoder().decode(WalletTransactionConfig.self, from: Data(json.utf8))

        #expect(config.templates.count == 1)
        #expect(config.merchants.isEmpty)
        #expect(config.cards.isEmpty)
    }
}
