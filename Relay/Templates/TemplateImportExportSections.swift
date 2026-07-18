//
//  TemplateImportExportSections.swift
//  Relay
//
//  Settings' backup import/export section, plus the legacy "YNAB Toolkit →
//  Relay Migration" Shortcut migration section. Export writes a full BackupData; import
//  goes through TemplateImportService, which also still accepts the older
//  template-only exports and the legacy bucket file.
//

import SwiftUI
import UniformTypeIdentifiers

struct BackupImportExportSection: View {
    @State private var showFileImporter = false
    @State private var isImporting = false
    @State private var importResultMessage: String?
    @State private var importErrorMessage: String?

    @State private var showExporter = false
    @State private var document: JSONFileDocument?
    @State private var didExport = false
    @State private var exportFlashTask: Task<Void, Never>?
    @State private var exportErrorMessage: String?

    var body: some View {
        Section {
            Button("Import Backup") {
                showFileImporter = true
            }
            .disabled(isImporting)

            Button {
                export()
            } label: {
                HStack {
                    Text("Export Backup")
                    Spacer()
                    // Flashes up on the row itself instead of pushing a new
                    // "Exported." line into the section — a self-clearing
                    // success tick.
                    if didExport {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.green)
                            .transition(.opacity.combined(with: .scale))
                    }
                }
            }

            if isImporting {
                ProgressView()
            }
            if let importResultMessage {
                Text(importResultMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let importErrorMessage {
                Text(importErrorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            if let exportErrorMessage {
                Text(exportErrorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } footer: {
            Text("Export your templates, auto-match rules, merchants, cards, import settings, and preferences as a JSON backup, or restore one. Account logins aren't included — you'll reconnect YNAB and Splitwise after restoring.")
                .footerText()
        }
        .cardRowBackground()
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.json]) { result in
            switch result {
            case .failure(let error):
                importResultMessage = nil
                importErrorMessage = "Failed to import: \(error.localizedDescription)"
            case .success(let url):
                Task { await importBuckets(from: url) }
            }
        }
        .fileExporter(
            isPresented: $showExporter,
            document: document,
            contentType: .json,
            defaultFilename: "Relay Backup"
        ) { result in
            switch result {
            case .success:
                exportErrorMessage = nil
                flashExportSuccess()
            case .failure(let error):
                exportErrorMessage = "Failed to export: \(error.localizedDescription)"
            }
        }
    }

    /// Shows the inline checkmark, then clears it after a beat. Cancels any
    /// in-flight flash first so a second export restarts the timer rather
    /// than letting the earlier one hide the fresh tick early.
    private func flashExportSuccess() {
        exportFlashTask?.cancel()
        withAnimation { didExport = true }
        exportFlashTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAnimation { didExport = false }
        }
    }

    private func importBuckets(from url: URL) async {
        importResultMessage = nil
        importErrorMessage = nil
        isImporting = true
        defer { isImporting = false }

        switch await TemplateImportService.importBuckets(from: url) {
        case .success(let message):
            importResultMessage = message
        case .failure(let error):
            importErrorMessage = error.message
        }
    }

    private func export() {
        exportErrorMessage = nil
        guard let data = try? BackupService.exportData() else {
            exportErrorMessage = "Failed to export: couldn't encode backup."
            return
        }
        document = JSONFileDocument(data: data)
        showExporter = true
    }
}

struct LegacyMigrationShortcutSection: View {
    var migration: LegacyMigrationCallbackHandler

    @Environment(\.openURL) private var openURL

    var body: some View {
        Section {
            Button("Install Migration Shortcut") {
                openURL(LegacyBucketMigrationShortcut.installURL)
            }
            Button("Run Migration") {
                migration.reset()
                openURL(LegacyBucketMigrationShortcut.runURL)
            }
            if let resultMessage = migration.resultMessage {
                Text(resultMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text("Pulls buckets and merchants straight out of the old \"YNAB Toolkit\" Shortcut's DataJar storage.")
                .footerText()
        }
        .cardRowBackground()
    }
}
