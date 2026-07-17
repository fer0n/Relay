//
//  JSONFileDocument.swift
//  Hazel
//

import SwiftUI
import UniformTypeIdentifiers

/// Minimal FileDocument wrapper so `.fileExporter` can save arbitrary JSON
/// `Data` — Hazel never reads a document back through this type, only
/// writes, since import goes through `.fileImporter` + JSONDecoder instead.
struct JSONFileDocument: FileDocument {
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
