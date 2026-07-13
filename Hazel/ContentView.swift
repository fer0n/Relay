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

#Preview {
    ContentView()
}
