//
//  SettingsView.swift
//  Hazel
//

import SwiftUI
import UniformTypeIdentifiers
import UserNotifications
import os

private let logger = Logger(subsystem: "com.pentlandFirth.Hazel", category: "SettingsView")

struct SettingsView: View {
    @State private var ynabAuth = YNABAuthService()
    @State private var splitwiseAuth = SplitwiseAuthService()
    @State private var didDeleteWalletConfig = false
    @State private var notificationsEnabled = NotificationsPreferenceStore.isEnabled
    @State private var showBucketFileImporter = false
    @State private var isImportingBuckets = false
    @State private var bucketImportResultMessage: String?
    @State private var bucketImportErrorMessage: String?
    @State private var showTemplateExporter = false
    @State private var templateExportDocument: JSONFileDocument?
    @State private var templateExportResultMessage: String?
    @State private var templateExportErrorMessage: String?
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
                    Text("Used to remind you if a wallet transaction is left unfinished or a queued transaction is still waiting to sync, so nothing silently gets lost.")
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
                    Button("Import Templates") {
                        showBucketFileImporter = true
                    }
                    .disabled(isImportingBuckets)
                    if isImportingBuckets {
                        ProgressView()
                    }
                    if let bucketImportResultMessage {
                        Text(bucketImportResultMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let bucketImportErrorMessage {
                        Text(bucketImportErrorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } footer: {
                    Text("Imports a JSON file exported from here, or the legacy shape the \"YNAB Toolkit\" Shortcut's DataJar config used.")
                        .footerText()
                }
                .cardRowBackground()

                Section {
                    Button("Export Templates") {
                        exportTemplates()
                    }
                    if let templateExportResultMessage {
                        Text(templateExportResultMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let templateExportErrorMessage {
                        Text(templateExportErrorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } footer: {
                    Text("Saves your templates, auto-match rules, merchants, and cards as a JSON file — a full backup you can re-import here later, including into a different device.")
                        .footerText()
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
            .fileImporter(isPresented: $showBucketFileImporter, allowedContentTypes: [.json]) { result in
                switch result {
                case .failure(let error):
                    bucketImportResultMessage = nil
                    bucketImportErrorMessage = "Failed to import: \(error.localizedDescription)"
                case .success(let url):
                    Task { await importBuckets(from: url) }
                }
            }
            .fileExporter(
                isPresented: $showTemplateExporter,
                document: templateExportDocument,
                contentType: .json,
                defaultFilename: "Hazel Templates"
            ) { result in
                switch result {
                case .success:
                    templateExportErrorMessage = nil
                    templateExportResultMessage = "Exported."
                case .failure(let error):
                    templateExportResultMessage = nil
                    templateExportErrorMessage = "Failed to export: \(error.localizedDescription)"
                }
            }
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

    private func importBuckets(from url: URL) async {
        bucketImportResultMessage = nil
        bucketImportErrorMessage = nil
        isImportingBuckets = true
        defer { isImportingBuckets = false }

        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

        do {
            let data = try Data(contentsOf: url)

            // Tries Hazel's own export shape first (a full WalletTransactionConfig
            // — no field translation needed), and only falls back to the legacy
            // bucket shape if that fails to decode. The two are structurally
            // distinct (different field names on `merchants`), so this never
            // misidentifies one as the other.
            if let nativeConfig = try? JSONDecoder().decode(WalletTransactionConfig.self, from: data) {
                var config = WalletTransactionConfigStore.load()
                let result = BucketImporter.mergeNative(nativeConfig, into: &config)
                try WalletTransactionConfigStore.save(config)
                logger.log("imported native export: \(result.importedTemplateCount, privacy: .public) templates, \(result.importedMerchantCount, privacy: .public) merchants")
                bucketImportResultMessage = summary(for: result)
                return
            }

            let file = try JSONDecoder().decode(BucketImportFile.self, from: data)

            var categories = YNABCategoryCacheStore.load() ?? []
            if let token = await YNABAuthService.validAccessToken(),
                let fetched = try? await YNABCategoryCacheStore.fetch(token: token) {
                categories = fetched
            }

            var config = WalletTransactionConfigStore.load()
            let result = BucketImporter.merge(file, into: &config, categories: categories)
            try WalletTransactionConfigStore.save(config)

            logger.log("imported \(result.importedBucketCount, privacy: .public) buckets, \(result.importedMerchantCount, privacy: .public) merchants")
            bucketImportResultMessage = summary(for: result)
        } catch {
            logger.error("failed to import buckets file: \(String(describing: error), privacy: .public)")
            bucketImportErrorMessage = "Failed to import: \(error.localizedDescription)"
        }
    }

    private func summary(for result: BucketImporter.Result) -> String {
        var message = "Imported \(result.importedBucketCount) bucket\(result.importedBucketCount == 1 ? "" : "s") and \(result.importedMerchantCount) merchant\(result.importedMerchantCount == 1 ? "" : "s")."
        if !result.unresolvedCategoryNames.isEmpty {
            message += " Couldn't match category: \(result.unresolvedCategoryNames.joined(separator: ", "))."
        }
        if result.skippedCardCount > 0 {
            message += " Skipped \(result.skippedCardCount) card mapping\(result.skippedCardCount == 1 ? "" : "s") — cards are linked automatically the first time you use them."
        }
        return message
    }

    private func summary(for result: BucketImporter.NativeMergeResult) -> String {
        "Imported \(result.importedTemplateCount) template\(result.importedTemplateCount == 1 ? "" : "s"), \(result.importedMerchantCount) merchant\(result.importedMerchantCount == 1 ? "" : "s"), and \(result.importedCardCount) card\(result.importedCardCount == 1 ? "" : "s")."
    }

    private func exportTemplates() {
        templateExportResultMessage = nil
        templateExportErrorMessage = nil
        let config = WalletTransactionConfigStore.load()
        let encoder = JSONEncoder()
        // Human-readable and byte-stable across exports of unchanged data —
        // this is a backup file a user might open/diff by hand, not a wire
        // format, so there's no cost to spending the extra whitespace.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config) else {
            templateExportErrorMessage = "Failed to export: couldn't encode templates."
            return
        }
        templateExportDocument = JSONFileDocument(data: data)
        showTemplateExporter = true
    }
}

/// Minimal FileDocument wrapper so `.fileExporter` can save arbitrary JSON
/// `Data` — Hazel never reads a document back through this type, only
/// writes, since import goes through `.fileImporter` + JSONDecoder instead.
private struct JSONFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private enum SettingsRoute: Hashable {
    case howHazelWorks
}

#Preview {
    SettingsView()
}
