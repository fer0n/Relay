//
//  TemplateImportExportSections.swift
//  Hazel
//
//  Settings' template import/export plus the legacy "YNAB Toolkit → Hazel"
//  Shortcut migration, combined into one section since they're all variations
//  on getting existing template data into Hazel.
//

import SwiftUI
import UniformTypeIdentifiers

struct TemplateImportExportSection: View {
    var migration: LegacyMigrationCallbackHandler

    @Environment(\.openURL) private var openURL

    @State private var showFileImporter = false
    @State private var isImporting = false
    @State private var importResultMessage: String?
    @State private var importErrorMessage: String?

    @State private var showExporter = false
    @State private var document: JSONFileDocument?
    @State private var exportResultMessage: String?
    @State private var exportErrorMessage: String?

    var body: some View {
        Section {
            Button("Import Templates") {
                showFileImporter = true
            }
            .disabled(isImporting)

            Button("Export Templates") {
                export()
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
            if let exportResultMessage {
                Text(exportResultMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let exportErrorMessage {
                Text(exportErrorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Button("Install Shortcut") {
                openURL(LegacyBucketMigrationShortcut.installURL, prefersInApp: true)
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
            Text("Export your templates, auto-match rules, merchants, and cards as a JSON backup, or import one back in. \"Run Migration\" instead pulls data from the old \"YNAB Toolkit\" Shortcut.")
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
            defaultFilename: "Hazel Templates"
        ) { result in
            switch result {
            case .success:
                exportErrorMessage = nil
                exportResultMessage = "Exported."
            case .failure(let error):
                exportResultMessage = nil
                exportErrorMessage = "Failed to export: \(error.localizedDescription)"
            }
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
        exportResultMessage = nil
        exportErrorMessage = nil
        let config = WalletTransactionConfigStore.load()
        let encoder = JSONEncoder()
        // Human-readable and byte-stable across exports of unchanged data —
        // this is a backup file a user might open/diff by hand, not a wire
        // format, so there's no cost to spending the extra whitespace.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config) else {
            exportErrorMessage = "Failed to export: couldn't encode templates."
            return
        }
        document = JSONFileDocument(data: data)
        showExporter = true
    }
}
