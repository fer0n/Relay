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
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
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

                Section {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Notifications")
                                .font(.headline)
                            Text(notificationStatusText)
                                .font(.subheadline)
                                .foregroundStyle(notificationStatus == .authorized ? .green : .secondary)
                        }
                        Spacer()
                        if notificationStatus != .authorized {
                            Button("Enable") {
                                requestNotificationPermission()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .task {
                        notificationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
                    }
                } footer: {
                    Text("Used to remind you if a wallet transaction is left unfinished, so it doesn't silently get lost.")
                }

                Section {
                    NavigationLink("How Hazel Works", value: SettingsRoute.howHazelWorks)
                }

                Section {
                    Button("Delete Wallet Transaction Config", role: .destructive) {
                        try? WalletTransactionConfigStore.delete()
                        didDeleteWalletConfig = true
                    }
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
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
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

    private var notificationStatusText: String {
        switch notificationStatus {
        case .authorized, .provisional, .ephemeral:
            "Enabled"
        case .denied:
            "Disabled — enable in iOS Settings"
        case .notDetermined:
            "Not enabled"
        @unknown default:
            "Not enabled"
        }
    }

    // Needed so TransactionDraftGuard's "Ensure Completion" reminders can
    // actually be delivered — requesting more than once is a no-op once the
    // user has already answered the system prompt, so this just re-reads
    // the resulting status rather than needing its own denied/authorized
    // branch.
    private func requestNotificationPermission() {
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            notificationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        }
    }
}

private enum SettingsRoute: Hashable {
    case howHazelWorks
}

#Preview {
    SettingsView()
}
