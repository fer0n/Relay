//
//  ContentView.swift
//  Hazel
//

import SwiftUI

struct ContentView: View {
    @State private var ynabAuth = YNABAuthService()
    @State private var splitwiseAuth = SplitwiseAuthService()
    @State private var didDeleteWalletConfig = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Hazel")
                    .font(.largeTitle.bold())
                    .padding(.bottom, 8)

                AccountConnectionRow(
                    title: "YNAB",
                    isConnected: ynabAuth.isAuthenticated,
                    connect: ynabAuth.signIn,
                    disconnect: ynabAuth.signOut
                )

                AccountConnectionRow(
                    title: "Splitwise",
                    isConnected: splitwiseAuth.isAuthenticated,
                    connect: splitwiseAuth.signIn,
                    disconnect: splitwiseAuth.signOut
                )

                if splitwiseAuth.isAuthenticated {
                    DefaultSplitwiseFriendRow()
                }

                NavigationLink {
                    TemplatesView()
                } label: {
                    HStack {
                        Text("Templates")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)

                NavigationLink {
                    HowHazelWorksView()
                } label: {
                    HStack {
                        Text("How Hazel Works")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)

                Spacer()

                Button("Delete Wallet Transaction Config") {
                    try? WalletTransactionConfigStore.delete()
                    didDeleteWalletConfig = true
                }
                .buttonStyle(.bordered)
                .tint(.red)
                if didDeleteWalletConfig {
                    Text("Deleted")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                // Required by YNAB's API Terms of Service (see CLAUDE.md) —
                // must be visible somewhere in the app, not just the privacy
                // policy.
                Text("We are not affiliated, associated, or in any way officially connected with YNAB or any of its subsidiaries or affiliates.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
        }
        // Picks up a token invalidated by an App Intent (e.g. an expired
        // YNAB token found while running a Shortcut) while this view's
        // YNABAuthService instance was already alive.
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                ynabAuth.refreshFromKeychain()
                splitwiseAuth.refreshFromKeychain()
            }
        }
    }
}

private struct AccountConnectionRow: View {
    let title: String
    let isConnected: Bool
    let connect: () -> Void
    let disconnect: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(title)
                    .font(.headline)
                Text(isConnected ? "Connected" : "Not connected")
                    .font(.subheadline)
                    .foregroundStyle(isConnected ? .green : .secondary)
            }
            Spacer()
            Button(isConnected ? "Disconnect" : "Connect") {
                if isConnected {
                    disconnect()
                } else {
                    connect()
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(isConnected ? .red : .accentColor)
        }
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Configures the default Splitwise friend `AddWalletTransactionToYNABIntent`
/// falls back to instead of asking live every time — see that intent's
/// `perform()` for the fallback logic.
private struct DefaultSplitwiseFriendRow: View {
    @State private var defaultFriend = SplitwiseDefaultFriendStore.load()
    @State private var friends: [SplitwiseFriend] = []

    var body: some View {
        // The whole row is the Menu's label (not just the chevron), so the
        // entire card is tappable rather than a small icon-sized target.
        Menu {
            ForEach(friends, id: \.id) { friend in
                Button(friend.fullName) { select(friend) }
            }
            if defaultFriend != nil {
                Divider()
                Button("Clear", role: .destructive, action: clear)
            }
        } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text("Default Splitwise Friend")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(defaultFriend?.fullName ?? "None set")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
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

#Preview {
    ContentView()
}
