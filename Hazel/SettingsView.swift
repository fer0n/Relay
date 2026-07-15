//
//  SettingsView.swift
//  Hazel
//

import SwiftUI

struct SettingsView: View {
    @State private var ynabAuth = YNABAuthService()
    @State private var splitwiseAuth = SplitwiseAuthService()
    @State private var didDeleteWalletConfig = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
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

                NavigationLink(value: SettingsRoute.howHazelWorks) {
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
            .navigationTitle("Settings")
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .howHazelWorks:
                    HowHazelWorksView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private enum SettingsRoute: Hashable {
    case howHazelWorks
}

#Preview {
    SettingsView()
}
