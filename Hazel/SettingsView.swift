//
//  SettingsView.swift
//  Hazel
//

import SwiftUI
import UserNotifications

struct SettingsView: View {
    @State private var ynabAuth = YNABAuthService()
    @State private var splitwiseAuth = SplitwiseAuthService()
    @State private var notificationsEnabled = NotificationsPreferenceStore.isEnabled
    @State private var migration = LegacyMigrationCallbackHandler()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    /// Dismisses Settings and asks ContentView to present onboarding once
    /// Settings has actually dismissed.
    var onRequestShowTutorial: () -> Void = {}
    /// Dismisses Settings and asks ContentView to present the automation
    /// tutorial once Settings has actually dismissed.
    var onRequestAutomationSetup: () -> Void = {}

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
                    Text("Used to remind you if a wallet transaction is left unfinished or a queued transaction is still waiting to sync, so nothing silently gets lost.")
                        .footerText()
                }
                .tint(.accentColor)
                .cardRowBackground()

                TemplateImportExportSection()

                LegacyMigrationShortcutSection(migration: migration)

                Section {
                    NavigationLink(value: SettingsRoute.howHazelWorks) {
                        RowLabel(title: "How Hazel Works")
                    }
                } footer: {
                    // Required by the YNAB API Terms of Service.
                    Text("We are not affiliated, associated, or in any way officially connected with YNAB or any of its subsidiaries or affiliates.")
                        .footerText()
                }
                .cardRowBackground()

                Section {
                    Button("Show Onboarding") {
                        onRequestShowTutorial()
                        dismiss()
                    }

                    Button("Automation Setup") {
                        onRequestAutomationSetup()
                        dismiss()
                    }
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
            .legacyMigrationCallback(migration, openURL: openURL)
        }
    }

    // Requesting more than once is a no-op once the user has already
    // answered the system prompt, so switching the toggle on again after a
    // denial just does nothing rather than needing its own branch.
    private func requestNotificationPermission() {
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        }
    }
}

private enum SettingsRoute: Hashable {
    case howHazelWorks
}

#Preview {
    SettingsView()
}
