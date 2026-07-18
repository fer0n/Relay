//
//  SplitwiseEntities.swift
//  Relay
//
//  AppEntity/EntityQuery type so Siri/Shortcuts can present a live picker
//  of the signed-in user's Splitwise friends.
//

import AppIntents
import os

private let logger = Logger(subsystem: "com.pentlandFirth.Relay", category: "SplitwiseEntities")

nonisolated struct SplitwiseFriendEntity: AppEntity {
    let id: Int
    let firstName: String
    /// Only used for `displayRepresentation` (i.e. when picking among
    /// several friends) so people sharing a first name are distinguishable
    /// there. Everywhere else — prompts, dialogs — use `firstName`.
    let fullName: String

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Splitwise Friend"
    static let defaultQuery = SplitwiseFriendQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(fullName)")
    }
}

nonisolated struct SplitwiseFriendQuery: EntityQuery {
    func entities(for identifiers: [Int]) async throws -> [SplitwiseFriendEntity] {
        await allFriends().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [SplitwiseFriendEntity] {
        await allFriends()
    }

    /// Never throws: Shortcuts resolves this query just to render an
    /// action's configuration sheet — e.g. "Add YNAB Transaction"'s
    /// optional "Split With" parameter — even when the user isn't using
    /// Splitwise at all. A throw here (e.g. not-authenticated) would break
    /// that sheet from loading. Missing auth instead surfaces from
    /// `perform()`/`SplitwiseExpenseHelper` when splitting is actually used.
    private func allFriends() async -> [SplitwiseFriendEntity] {
        guard let token = SplitwiseAuthService.currentAccessToken else {
            logger.error("SplitwiseFriendQuery: no access token in Keychain")
            return []
        }
        do {
            let friends = try await SplitwiseFriendCacheStore.fetch(token: token)
            logger.log("SplitwiseFriendQuery: fetched \(friends.count, privacy: .public) friends")
            return SplitwiseFriendUsageStore.sorted(friends).map { SplitwiseFriendEntity(id: $0.id, firstName: $0.firstName, fullName: $0.fullName) }
        } catch {
            // Also invalidates the stored token on a 401, so Relay's own
            // UI reflects "Not Connected" instead of silently failing.
            let mapped = SplitwiseIntentError.from(error)
            logger.error("SplitwiseFriendQuery: fetchFriends failed: \(String(describing: mapped), privacy: .public)")
            return []
        }
    }
}
