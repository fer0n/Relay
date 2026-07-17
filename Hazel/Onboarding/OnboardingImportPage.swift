//
//  OnboardingImportPage.swift
//  Hazel
//

import SwiftUI

struct OnboardingImportPage: View {
    /// Owned by `OnboardingView`; `true` shows migration actions.
    @Binding var usesLegacyShortcut: Bool?
    @Binding var didPrepareMigration: Bool
    let migration: LegacyMigrationCallbackHandler

    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack {
            Group {
                switch usesLegacyShortcut {
                case true:
                    migrationSteps
                case false, nil:
                    // Same placeholder style as OnboardingNotificationsPage —
                    // a plain large secondary SF Symbol, no text.
                    Image(systemName: "yensign")
                        .font(.system(size: 100))
                        .foregroundStyle(.secondary)
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
                    Label("Migration Shortcut", systemImage: didPrepareMigration ? "checkmark" : "circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .tint(Color.foregroundColor)
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
                .buttonStyle(.bordered)
                .tint(Color.foregroundColor)
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
    OnboardingImportPage(
        usesLegacyShortcut: .constant(nil),
        didPrepareMigration: .constant(false),
        migration: LegacyMigrationCallbackHandler()
    )
}
