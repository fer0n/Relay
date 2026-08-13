//
//  SplitwiseEntities.swift
//  Relay
//
//  AppEntity/EntityQuery type so Siri/Shortcuts can present a live picker of
//  the signed-in user's Splitwise friends and groups.
//
//  Both kinds share one entity, so a shortcut's "Split With" parameter can
//  offer either without the action growing a second field. They're told apart
//  by `kind`, and the entity id carries it too — Splitwise numbers friends and
//  groups separately, so an id alone doesn't identify one.
//

import AppIntents
import os

private nonisolated let logger = Logger(subsystem: Const.loggerSubsystem, category: "SplitwiseEntities")

nonisolated struct SplitwiseSplitTargetEntity: AppEntity {
    enum Kind: String {
        case friend, group
    }

    let kind: Kind
    /// Splitwise's own id for the friend or group. Unique only within a kind,
    /// which is why it isn't the entity id.
    let splitwiseId: Int
    let firstName: String
    /// Only used for `displayRepresentation` (i.e. when picking among several
    /// friends) so people sharing a first name are distinguishable there.
    /// Everywhere else — prompts, dialogs — use `firstName`.
    let fullName: String

    init(kind: Kind = .friend, splitwiseId: Int, firstName: String, fullName: String) {
        self.kind = kind
        self.splitwiseId = splitwiseId
        self.firstName = firstName
        self.fullName = fullName
    }

    /// "friend-42" / "group-7". A string rather than the raw Splitwise id
    /// because Shortcuts stores this to remember the pick, and the two kinds
    /// share a number space.
    var id: String { "\(kind.rawValue)-\(splitwiseId)" }

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Splitwise Friend or Group"
    static let defaultQuery = SplitwiseSplitTargetQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(fullName)")
    }
}

extension SplitwiseSplitTargetEntity {
    /// Builds an entity straight from a template's cached target
    /// (`WalletTransactionConfig.Template.splitwiseTarget`), which carries the
    /// same fields.
    init(cachedTarget: WalletTransactionConfig.CachedSplitTarget) {
        self.init(
            kind: cachedTarget.isGroup ? .group : .friend,
            splitwiseId: cachedTarget.id,
            firstName: cachedTarget.firstName,
            fullName: cachedTarget.fullName
        )
    }

    init(friend: SplitwiseFriend) {
        self.init(splitwiseId: friend.id, firstName: friend.firstName, fullName: friend.fullName)
    }

    init(defaultFriend: SplitwiseDefaultFriend) {
        self.init(
            kind: defaultFriend.isGroup ? .group : .friend,
            splitwiseId: defaultFriend.id,
            firstName: defaultFriend.firstName,
            fullName: defaultFriend.fullName
        )
    }

    /// The group's name stands in for both name fields — a group has no first
    /// name, and the dialogs that say "split with \(firstName)" read fine with
    /// it ("split with Flat").
    init(group: SplitwiseGroup) {
        self.init(kind: .group, splitwiseId: group.id, firstName: group.name, fullName: group.name)
    }

    /// What a template or a draft's pending split context stores.
    var cachedTarget: WalletTransactionConfig.CachedSplitTarget {
        WalletTransactionConfig.CachedSplitTarget(
            id: splitwiseId,
            firstName: firstName,
            fullName: fullName,
            isGroup: kind == .group
        )
    }
}

nonisolated struct SplitwiseSplitTargetQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [SplitwiseSplitTargetEntity] {
        await allTargets().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [SplitwiseSplitTargetEntity] {
        await allTargets()
    }

    /// Friends first, then groups — a group is the rarer pick, and Shortcuts
    /// shows this list in order.
    private func allTargets() async -> [SplitwiseSplitTargetEntity] {
        await allFriends() + allGroups()
    }

    /// Never throws: Shortcuts resolves this query just to render an
    /// action's configuration sheet — e.g. "Add YNAB Transaction"'s
    /// optional "Split With" parameter — even when the user isn't using
    /// Splitwise at all. A throw here (e.g. not-authenticated) would break
    /// that sheet from loading. Missing auth instead surfaces from
    /// `perform()`/`SplitwiseExpenseHelper` when splitting is actually used.
    private func allFriends() async -> [SplitwiseSplitTargetEntity] {
        guard let token = SplitwiseAuthService.currentAccessToken else {
            logger.error("SplitwiseSplitTargetQuery: no access token in Keychain")
            return []
        }
        do {
            let friends = try await SplitwiseFriendCacheStore.fetch(token: token)
            logger.log("SplitwiseSplitTargetQuery: fetched \(friends.count, privacy: .public) friends")
            return SplitwiseFriendUsageStore.sorted(friends).map { SplitwiseSplitTargetEntity(friend: $0) }
        } catch {
            // Also invalidates the stored token on a 401, so Relay's own
            // UI reflects "Not Connected" instead of silently failing.
            let mapped = SplitwiseIntentError.from(error)
            logger.error("SplitwiseSplitTargetQuery: fetchFriends failed: \(String(describing: mapped), privacy: .public)")
            return []
        }
    }

    /// Never throws, for the same reason `allFriends()` doesn't. A group with
    /// no members is left out: there'd be nobody to bill.
    private func allGroups() async -> [SplitwiseSplitTargetEntity] {
        guard let token = SplitwiseAuthService.currentAccessToken else { return [] }
        do {
            let groups = try await SplitwiseGroupCacheStore.fetch(token: token)
            logger.log("SplitwiseSplitTargetQuery: fetched \(groups.count, privacy: .public) groups")
            return groups.filter { !$0.memberList.isEmpty }.map { SplitwiseSplitTargetEntity(group: $0) }
        } catch {
            let mapped = SplitwiseIntentError.from(error)
            logger.error("SplitwiseSplitTargetQuery: fetchGroups failed: \(String(describing: mapped), privacy: .public)")
            return []
        }
    }
}
