//
//  ImportTemplateFileIntent.swift
//  Hazel
//
//  Exists solely for the "YNAB Toolkit → Hazel" migration Shortcut, which
//  hands Hazel the old "Transaction → YNAB" Shortcut's DataJar buckets/
//  merchants/cards through this "Import Template File" action — pulled
//  straight out of Data Jar via "Get Value for Key", without an intermediate
//  Save File step: Shortcuts coerces non-file output (text, dictionaries)
//  into an ephemeral IntentFile automatically when a parameter is typed as
//  File. Deliberately kept out of HazelShortcuts' promoted App Shortcuts
//  (see the note there) now that the in-app feature is a full backup, not a
//  template file — but the action must stay defined or the installed
//  migration Shortcut can't find it. Routes through TemplateImportService,
//  whose legacy-bucket fallback path does the actual DataJar import.
//

import AppIntents
import UniformTypeIdentifiers

nonisolated struct ImportTemplateFileIntent: AppIntent {
    static let title: LocalizedStringResource = "Import Template File"
    static let description = IntentDescription("Imports a Hazel templates JSON file, or the legacy shape the \"YNAB Toolkit\" Shortcut's DataJar config used.")

    @Parameter(title: "File", supportedContentTypes: [.json, .data])
    var file: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("Import \(\.$file) as templates")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        switch await TemplateImportService.importBuckets(from: file.data) {
        case .success(let message):
            return .result(dialog: IntentDialog(stringLiteral: message))
        case .failure(let error):
            throw TemplateImportIntentError.importFailed(error.message)
        }
    }
}

enum TemplateImportIntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
    case importFailed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .importFailed(let message):
            return LocalizedStringResource(stringLiteral: message)
        }
    }
}
