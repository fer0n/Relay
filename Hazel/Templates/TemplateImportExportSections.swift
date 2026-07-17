//
//  TemplateImportExportSections.swift
//  Hazel
//
//  Settings' "Import Templates" and "Export Templates" sections, each owning
//  its own file-picker state independent of the rest of the screen.
//

import SwiftUI
import UniformTypeIdentifiers

struct TemplateImportSection: View {
    @State private var showFileImporter = false
    @State private var isImporting = false
    @State private var resultMessage: String?
    @State private var errorMessage: String?

    var body: some View {
        Section {
            Button("Import Templates") {
                showFileImporter = true
            }
            .disabled(isImporting)
            if isImporting {
                ProgressView()
            }
            if let resultMessage {
                Text(resultMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } footer: {
            Text("Imports a JSON file exported from here, or the legacy shape the \"YNAB Toolkit\" Shortcut's DataJar config used.")
                .footerText()
        }
        .cardRowBackground()
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.json]) { result in
            switch result {
            case .failure(let error):
                resultMessage = nil
                errorMessage = "Failed to import: \(error.localizedDescription)"
            case .success(let url):
                Task { await importBuckets(from: url) }
            }
        }
    }

    private func importBuckets(from url: URL) async {
        resultMessage = nil
        errorMessage = nil
        isImporting = true
        defer { isImporting = false }

        switch await TemplateImportService.importBuckets(from: url) {
        case .success(let message):
            resultMessage = message
        case .failure(let error):
            errorMessage = error.message
        }
    }
}

struct TemplateExportSection: View {
    @State private var showExporter = false
    @State private var document: JSONFileDocument?
    @State private var resultMessage: String?
    @State private var errorMessage: String?

    var body: some View {
        Section {
            Button("Export Templates") {
                export()
            }
            if let resultMessage {
                Text(resultMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } footer: {
            Text("Saves your templates, auto-match rules, merchants, and cards as a JSON file — a full backup you can re-import here later, including into a different device.")
                .footerText()
        }
        .cardRowBackground()
        .fileExporter(
            isPresented: $showExporter,
            document: document,
            contentType: .json,
            defaultFilename: "Hazel Templates"
        ) { result in
            switch result {
            case .success:
                errorMessage = nil
                resultMessage = "Exported."
            case .failure(let error):
                resultMessage = nil
                errorMessage = "Failed to export: \(error.localizedDescription)"
            }
        }
    }

    private func export() {
        resultMessage = nil
        errorMessage = nil
        let config = WalletTransactionConfigStore.load()
        let encoder = JSONEncoder()
        // Human-readable and byte-stable across exports of unchanged data —
        // this is a backup file a user might open/diff by hand, not a wire
        // format, so there's no cost to spending the extra whitespace.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config) else {
            errorMessage = "Failed to export: couldn't encode templates."
            return
        }
        document = JSONFileDocument(data: data)
        showExporter = true
    }
}
