//
//  DateFormatEntity.swift
//  Relay
//
//  Used only as the `among:` list for ImportYNABFileIntent's date-format
//  requestDisambiguation, when DateFormatDetector can't narrow a statement's
//  date strings down to a single candidate format on its own.
//

import AppIntents

nonisolated struct DateFormatEntity: AppEntity {
    let format: String
    /// The file's sample date string, parsed with `format` and re-rendered
    /// for display, so the user can tell "13/07/2026" apart from
    /// "07/13/2026" at a glance instead of picking a raw format string.
    let parsedPreview: String?

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Date Format"
    static let defaultQuery = DateFormatQuery()

    var id: String { format }

    var displayRepresentation: DisplayRepresentation {
        if let parsedPreview {
            DisplayRepresentation(title: "\(parsedPreview)", subtitle: "\(format)")
        } else {
            DisplayRepresentation(title: "\(format)")
        }
    }
}

nonisolated struct DateFormatQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [DateFormatEntity] {
        identifiers.map { DateFormatEntity(format: $0, parsedPreview: nil) }
    }
}
