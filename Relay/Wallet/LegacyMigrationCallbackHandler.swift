//
//  LegacyMigrationCallbackHandler.swift
//  Relay
//
//  Shared x-callback-url handling for LegacyBucketMigrationShortcut — both
//  SettingsView and the onboarding import page let the user run the same
//  Shortcut and need identical success/error parsing plus the same
//  "Shortcut Error" alert.
//

import SwiftUI

@Observable
final class LegacyMigrationCallbackHandler {
    private(set) var resultMessage: String?
    private(set) var errorMessage: String?
    var showErrorAlert = false

    func reset() {
        resultMessage = nil
        errorMessage = nil
        showErrorAlert = false
    }

    func handle(_ url: URL) {
        switch url.host {
        case LegacyBucketMigrationShortcut.successHost:
            errorMessage = nil
            let config = WalletTransactionConfigStore.load()
            resultMessage = "Migration complete — you now have \(config.templates.count) template\(config.templates.count == 1 ? "" : "s") and \(config.merchants.count) merchant\(config.merchants.count == 1 ? "" : "s")."
        case LegacyBucketMigrationShortcut.errorHost:
            resultMessage = nil
            let message = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "errorMessage" })?.value
            errorMessage = message.map { "Shortcut failed: \($0)" } ?? "Shortcut failed or was cancelled."
            showErrorAlert = true
        default:
            break
        }
    }
}

extension View {
    /// Wires up `.onOpenURL` + the "Shortcut Error" alert for a
    /// `LegacyMigrationCallbackHandler`. Doesn't include the Install/Run
    /// buttons themselves since those differ in visual chrome per call site.
    func legacyMigrationCallback(_ handler: LegacyMigrationCallbackHandler, openURL: OpenURLAction) -> some View {
        onOpenURL { url in
            handler.handle(url)
        }
        .alert(
            "Shortcut Error",
            isPresented: Binding(
                get: { handler.showErrorAlert },
                set: { handler.showErrorAlert = $0 }
            ),
            presenting: handler.errorMessage
        ) { _ in
            Button("Install Shortcut") {
                handler.showErrorAlert = false
                Task { @MainActor in
                    openURL(LegacyBucketMigrationShortcut.installURL)
                }
            }
            Button("OK", role: .cancel) { }
        } message: { message in
            Text(message)
        }
    }
}
