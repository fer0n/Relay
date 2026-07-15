//
//  SettingsView.swift
//  Hazel
//

import SwiftUI
import UserNotifications

struct SettingsView: View {
    @State private var ynabAuth = YNABAuthService()
    @State private var splitwiseAuth = SplitwiseAuthService()
    @State private var didDeleteWalletConfig = false
    @State private var notificationsEnabled = NotificationsPreferenceStore.isEnabled
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
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
                }
                .cardRowBackground()

                Section {
                    Toggle("Notifications", isOn: $notificationsEnabled)
                        .onChange(of: notificationsEnabled) { _, newValue in
                            NotificationsPreferenceStore.isEnabled = newValue
                            if newValue {
                                requestNotificationPermission()
                            }
                        }
                } footer: {
                    Text("Used to remind you if a wallet transaction is left unfinished, so it doesn't silently get lost.")
                        .footerText()
                }
                .tint(.accentColor)
                .cardRowBackground()

                Section {
                    NavigationLink(value: SettingsRoute.howHazelWorks) {
                        RowLabel(title: "How Hazel Works")
                    }
                }
                .cardRowBackground()

                Section {
                    Button("Delete Wallet Transaction Config", role: .destructive) {
                        try? WalletTransactionConfigStore.delete()
                        didDeleteWalletConfig = true
                    }
                    .foregroundStyle(.red)
                    if didDeleteWalletConfig {
                        Text("Deleted")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    // Required by YNAB's API Terms of Service (see CLAUDE.md) —
                    // must be visible somewhere in the app, not just the privacy
                    // policy.
                    Text("Hazel is not affiliated, associated, or in any way officially connected with YNAB or any of its subsidiaries or affiliates.")
                        .footerText()
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
                .cardRowBackground()
            }
            .themedList(background: .sheetBackgroundColor)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .howHazelWorks:
                    HowHazelWorksView()
                }
            }
        }
    }

    // Requesting more than once is a no-op once the user has already
    // answered the system prompt, so switching the toggle on again after a
    // denial just does nothing rather than needing its own branch.
    private func requestNotificationPermission() {
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        }
    }
}

private enum SettingsRoute: Hashable {
    case howHazelWorks
}

#Preview {
    SettingsView()
}
