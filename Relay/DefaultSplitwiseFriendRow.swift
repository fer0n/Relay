//
//  DefaultSplitwiseFriendRow.swift
//  Relay
//

import SwiftUI

/// Configures the default Splitwise friend `AddWalletTransactionToYNABIntent`
/// falls back to instead of asking live every time — see that intent's
/// `perform()` for the fallback logic.
struct DefaultSplitwiseFriendRow: View {
    @State private var defaultFriend = SplitwiseDefaultFriendStore.load()
    @State private var friends: [SplitwiseFriend] = []

    var body: some View {
        HStack {
            Text("Splitwise Default")
            
        Menu {
            splitwiseFriendMenuButtons(friends) { select($0) }
            if defaultFriend != nil {
                Divider()
                Button("Clear", role: .destructive, action: clear)
            }
        } label: {
                Spacer()
                Text(defaultFriend?.fullName ?? "None")
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.up.chevron.down")
                    .foregroundStyle(.secondary)
                    .imageScale(.small)
            }
            .contentShape(Rectangle())
        }
        .task {
            if let cached = SplitwiseFriendCacheStore.load() {
                friends = SplitwiseFriendUsageStore.sorted(cached)
            }
            guard let token = SplitwiseAuthService.currentAccessToken else { return }
            let fetched = (try? await SplitwiseFriendCacheStore.fetch(token: token)) ?? friends
            friends = SplitwiseFriendUsageStore.sorted(fetched)
        }
    }

    private func select(_ friend: SplitwiseFriend) {
        let value = SplitwiseDefaultFriend(id: friend.id, firstName: friend.firstName, fullName: friend.fullName)
        defaultFriend = value
        try? SplitwiseDefaultFriendStore.save(value)
    }

    private func clear() {
        defaultFriend = nil
        try? SplitwiseDefaultFriendStore.delete()
    }
}
