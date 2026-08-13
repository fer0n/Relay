//
//  DefaultSplitwiseFriendRow.swift
//  Relay
//

import SwiftUI

/// Configures the default Splitwise friend — or group — `AddWalletTransactionToYNABIntent`
/// falls back to instead of asking live every time; see that intent's
/// `perform()` for the fallback logic.
struct DefaultSplitwiseFriendRow: View {
    @State private var defaultFriend = SplitwiseDefaultFriendStore.load()
    @State private var friends: [SplitwiseFriend] = []
    @State private var groups: [SplitwiseGroup] = []

    var body: some View {
        HStack {
            Text("Split with (default)")
            Spacer()
            Menu {
                splitwiseFriendMenuButtons(friends) { select($0) }
                // Groups after a separator rather than mixed in: they bill a
                // whole membership, which is a different kind of answer to
                // "who do I split with" than one person.
                if !selectableGroups.isEmpty {
                    Divider()
                    ForEach(selectableGroups, id: \.id) { group in
                        Button(group.name) { select(group) }
                    }
                }
                if defaultFriend != nil {
                    Divider()
                    Button("Clear", role: .destructive, action: clear)
                }
            } label: {
                MenuPickerLabel { Text(defaultFriend?.fullName ?? "None") }
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .task {
            if let cached = SplitwiseFriendCacheStore.load() {
                friends = SplitwiseFriendUsageStore.sorted(cached)
            }
            if let cached = SplitwiseGroupCacheStore.load() {
                groups = cached
            }
            // Show the cache instantly; skip the live fetch while it's fresh
            // so re-opening this picker doesn't re-hit Splitwise.
            guard let token = SplitwiseAuthService.currentAccessToken else { return }
            if SplitwiseFriendCacheStore.isStale {
                let fetched = (try? await SplitwiseFriendCacheStore.fetch(token: token)) ?? friends
                friends = SplitwiseFriendUsageStore.sorted(fetched)
            }
            if SplitwiseGroupCacheStore.isStale {
                groups = (try? await SplitwiseGroupCacheStore.fetch(token: token)) ?? groups
            }
        }
    }

    /// A group with nobody in it has no one to bill.
    private var selectableGroups: [SplitwiseGroup] {
        groups.filter { !$0.memberList.isEmpty }
    }

    private func select(_ friend: SplitwiseFriend) {
        save(SplitwiseDefaultFriend(id: friend.id, firstName: friend.firstName, fullName: friend.fullName))
    }

    /// The group's name stands in for both name fields, matching how a group
    /// reads everywhere else a split target is named.
    private func select(_ group: SplitwiseGroup) {
        save(SplitwiseDefaultFriend(id: group.id, firstName: group.name, fullName: group.name, isGroup: true))
    }

    private func save(_ value: SplitwiseDefaultFriend) {
        defaultFriend = value
        try? SplitwiseDefaultFriendStore.save(value)
    }

    private func clear() {
        defaultFriend = nil
        try? SplitwiseDefaultFriendStore.delete()
    }
}
