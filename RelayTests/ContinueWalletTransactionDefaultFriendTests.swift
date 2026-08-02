//
//  ContinueWalletTransactionDefaultFriendTests.swift
//  RelayTests
//
//  The friend picker's "Default (…)" option leaves `selectedFriendId` nil,
//  which canSubmit has always accepted. Submitting used to look the id up in
//  the loaded friends list and bail with "Pick a Splitwise friend" — so a draft
//  demanded a specific friend even though the default was right there. These
//  cover the resolution the submit paths now share.
//

import Foundation
import Testing
@testable import Relay

@MainActor
struct ContinueWalletTransactionDefaultFriendTests {
    private static let merchant = "REWE SAGT DANKE 1234 //BERLIN/DE"
    private static let alex = SplitwiseDefaultFriend(id: 42, firstName: "Alex", fullName: "Alex Kim")

    /// The store is a real file in the test host's container, so each test puts
    /// back whatever was there.
    private static func withDefaultFriend<T>(_ friend: SplitwiseDefaultFriend?, _ body: () throws -> T) rethrows -> T {
        let previous = SplitwiseDefaultFriendStore.load()
        defer {
            if let previous {
                try? SplitwiseDefaultFriendStore.save(previous)
            } else {
                try? SplitwiseDefaultFriendStore.delete()
            }
        }
        if let friend {
            try? SplitwiseDefaultFriendStore.save(friend)
        } else {
            try? SplitwiseDefaultFriendStore.delete()
        }
        return try body()
    }

    private static func splitwiseDraftModel() -> ContinueWalletTransactionModel {
        let draft = TransactionDraft(
            id: UUID(),
            startedAt: Date(),
            payload: .splitwiseWallet(merchant: merchant, amount: 32.10)
        )
        // isAuthenticatedOverride skips the Keychain gate so init runs the
        // real config-resolution path against an (empty) test config.
        return ContinueWalletTransactionModel(draft: draft, isAuthenticatedOverride: true)
    }

    @Test
    func defaultFriendResolvesWhenNothingSpecificIsPicked() {
        Self.withDefaultFriend(Self.alex) {
            let model = Self.splitwiseDraftModel()
            // Unknown merchant, no template friend: the row shows "Default (Alex)".
            #expect(model.selectedFriendId == nil)
            #expect(model.friendNoneLabel == "Default (Alex)")
            #expect(!model.friendRowIsIncomplete)

            let resolved = model.resolvedSplitFriend
            #expect(resolved?.id == 42)
            #expect(resolved?.fullName == "Alex Kim")
        }
    }

    @Test
    func defaultFriendCarriesTheDraftThroughCanSubmit() {
        Self.withDefaultFriend(Self.alex) {
            let model = Self.splitwiseDraftModel()
            // The one thing an untemplated draft really does have to be told.
            model.splitwiseRuntimeChoice = .always

            #expect(model.canSubmit)
        }
    }

    @Test
    func aPickedFriendStillResolvesWithAnEmptyFriendsList() {
        Self.withDefaultFriend(Self.alex) {
            let model = Self.splitwiseDraftModel()
            // Nothing cached to look the id up in (offline, cold cache).
            #expect(model.friends.isEmpty)
            model.selectedFriendId = Self.alex.id

            #expect(model.resolvedSplitFriend?.id == 42)
        }
    }

    @Test
    func noDefaultAndNoPickStillLeavesTheFriendUnresolved() {
        Self.withDefaultFriend(nil) {
            let model = Self.splitwiseDraftModel()
            #expect(model.friendRowIsIncomplete)
            #expect(model.resolvedSplitFriend == nil)

            model.splitwiseRuntimeChoice = .always
            #expect(!model.canSubmit)
        }
    }
}
