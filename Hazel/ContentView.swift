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
        }
        .padding()
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
        HStack {
            VStack(alignment: .leading) {
                Text("Default Splitwise Friend")
                    .font(.headline)
                Text(defaultFriend?.name ?? "None set")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                ForEach(friends, id: \.id) { friend in
                    Button(friend.firstName) { select(friend) }
                }
                if defaultFriend != nil {
                    Divider()
                    Button("Clear", role: .destructive, action: clear)
                }
            } label: {
                Image(systemName: "chevron.up.chevron.down")
            }
        }
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        .task {
            guard let token = SplitwiseAuthService.currentAccessToken else { return }
            friends = (try? await SplitwiseService.fetchFriends(token: token)) ?? []
        }
    }

    private func select(_ friend: SplitwiseFriend) {
        let value = SplitwiseDefaultFriend(id: friend.id, name: friend.firstName)
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
