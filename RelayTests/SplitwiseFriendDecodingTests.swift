//
//  SplitwiseFriendDecodingTests.swift
//  RelayTests
//
//  Regression coverage for adding `picture` to SplitwiseFriend (see
//  SplitwiseModels.swift): the field is Optional, so the compiler-synthesized
//  decoder already uses `decodeIfPresent` for it — this just guards that
//  disk-cached friend lists written by a build before `picture` existed
//  (see WalletTransactionConfigDecodingTests for the shape of bug this
//  protects against) still decode, and that a `picture` object present in a
//  live API response decodes into `avatarURL` correctly.
//

import Foundation
import Testing
@testable import Relay

struct SplitwiseFriendDecodingTests {
    private static let legacyJSON = """
    {
      "id": 42,
      "first_name": "Sam",
      "last_name": "Rivera",
      "balance": [ { "currency_code": "EUR", "amount": "12.34" } ]
    }
    """

    @Test
    func decodesFriendWrittenBeforePictureExisted() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let friend = try decoder.decode(SplitwiseFriend.self, from: Data(Self.legacyJSON.utf8))

        #expect(friend.fullName == "Sam Rivera")
        #expect(friend.avatarURL == nil)
    }

    @Test
    func decodesPictureAndPicksAvatarURL() throws {
        let json = """
        {
          "id": 42,
          "first_name": "Sam",
          "last_name": "Rivera",
          "balance": [],
          "picture": {
            "small": "https://example.com/small.jpg",
            "medium": "https://example.com/medium.jpg",
            "large": "https://example.com/large.jpg"
          }
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let friend = try decoder.decode(SplitwiseFriend.self, from: Data(json.utf8))

        #expect(friend.avatarURL == URL(string: "https://example.com/medium.jpg"))
    }

    @Test
    func fallsBackToSmallWhenMediumIsMissing() throws {
        let json = """
        {
          "id": 42,
          "first_name": "Sam",
          "last_name": null,
          "balance": [],
          "picture": { "small": "https://example.com/small.jpg" }
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let friend = try decoder.decode(SplitwiseFriend.self, from: Data(json.utf8))

        #expect(friend.avatarURL == URL(string: "https://example.com/small.jpg"))
    }
}
