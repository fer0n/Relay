//
//  ContinueWalletTransactionMemoTests.swift
//  RelayTests
//
//  Covers the Memo field on the YNAB ("Both") side of the transaction form:
//  it fills YNAB's own memo field, and — because a Splitwise expense has only
//  one text field — it's folded into the split's description as
//  "<Payee>: <memo>" rather than being dropped there.
//

import Foundation
import Testing
@testable import Relay

@MainActor
struct ContinueWalletTransactionMemoTests {
    private static func ynabDraftModel() -> ContinueWalletTransactionModel {
        let draft = TransactionDraft(
            id: UUID(),
            startedAt: Date(),
            payload: .ynabWallet(merchant: "Coffee Shop", amount: 4.50, card: "Visa")
        )
        // isAuthenticatedOverride skips the Keychain gate so init runs the
        // real config-resolution path against an (empty) test config.
        return ContinueWalletTransactionModel(draft: draft, isAuthenticatedOverride: true)
    }

    @Test
    func blankMemoSendsNoMemoAndLeavesTheSplitDescriptionAsThePayee() {
        let model = Self.ynabDraftModel()
        model.payeeText = "Rewe"

        #expect(model.memoText.isEmpty)
        #expect(model.ynabMemo == nil)
        #expect(model.splitDescription == "Rewe")
    }

    @Test
    func whitespaceOnlyMemoCountsAsBlank() {
        let model = Self.ynabDraftModel()
        model.payeeText = "Rewe"
        model.memoText = "   "

        #expect(model.ynabMemo == nil)
        #expect(model.splitDescription == "Rewe")
    }

    @Test
    func typedMemoIsTrimmedAndAppendedToTheSplitDescription() {
        let model = Self.ynabDraftModel()
        model.payeeText = "  Rewe  "
        model.memoText = "  Weekly groceries  "

        #expect(model.ynabPayeeName == "Rewe")
        #expect(model.ynabMemo == "Weekly groceries")
        #expect(model.splitDescription == "Rewe: Weekly groceries")
    }
}
