//
//  OnboardingImportPage.swift
//  Hazel
//

import SwiftUI

struct OnboardingImportPage: View {
    /// Owned by `OnboardingView` so it can gate the sheet's Done button —
    /// `nil` until the user answers the inline "have you been using the
    /// shortcut" prompt below.
    @Binding var usesLegacyShortcut: Bool?
    /// Owned by `OnboardingView` so it can de-emphasize the Done button
    /// until the migration actually runs.
    let migration: LegacyMigrationCallbackHandler

    @State private var didPrepareMigration = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack {
            Group {
                switch usesLegacyShortcut {
                case true:
                    migrationSteps
                case false:
                    // Same placeholder style as OnboardingNotificationsPage —
                    // a plain large secondary SF Symbol, no text.
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 100))
                        .foregroundStyle(.secondary)
                case nil:
                    // A real .alert() would pop up as a floating system modal —
                    // this instead mimics the alert's look (title/message over a
                    // divider, then a button row) but stays laid out inline in
                    // the page like any other content.
                    InlineAlertCard(
                        title: "Have you been using the YNAB Toolkit Shortcut?",
                        buttons: [
                            ("Yes", { usesLegacyShortcut = true }),
                            ("No", { usesLegacyShortcut = false }),
                        ]
                    )
                    .padding(.horizontal, 40)
                }
            }
            .id(usesLegacyShortcut)
            .transition(.opacity)
        }
        .animation(.easeInOut(duration: 0.2), value: usesLegacyShortcut)
        .padding(.top, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .legacyMigrationCallback(migration, openURL: openURL)
    }

    private var migrationSteps: some View {
        VStack(spacing: 12) {
            VStack(spacing: 12) {
                Button {
                    openURL(LegacyBucketMigrationShortcut.installURL, prefersInApp: true)
                    didPrepareMigration = true
                } label: {
                    Label("Get Shortcut", systemImage: didPrepareMigration ? "checkmark" : "circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .disabled(didPrepareMigration)

                Button {
                    migration.reset()
                    openURL(LegacyBucketMigrationShortcut.runURL)
                } label: {
                    Label("Start Migration", systemImage: migration.resultMessage != nil ? "checkmark" : "circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .disabled(migration.resultMessage != nil)
            }
            .fixedSize()

            if let resultMessage = migration.resultMessage {
                Text(resultMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
    }
}

#Preview {
    OnboardingImportPage(usesLegacyShortcut: .constant(nil), migration: LegacyMigrationCallbackHandler())
}
