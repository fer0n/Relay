//
//  StatementColumnEntity.swift
//  Hazel
//
//  Used only as the `among:` list for ImportYNABFileIntent's
//  requestDisambiguation calls ("which column is the date/payee/memo/
//  amount?") — the choices are specific to one file's header, not a global
//  lookup, so `id` self-encodes everything needed to redisplay a column
//  without re-reading the source file.
//

import AppIntents

nonisolated struct StatementColumnEntity: AppEntity {
    let index: Int
    let header: String
    let sampleValue: String?

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Statement Column"
    static let defaultQuery = StatementColumnQuery()

    var id: String {
        [String(index), header, sampleValue ?? ""].joined(separator: "\u{1}")
    }

    var displayRepresentation: DisplayRepresentation {
        if let sampleValue, !sampleValue.isEmpty {
            DisplayRepresentation(title: "\(header)", subtitle: "\(sampleValue)")
        } else {
            DisplayRepresentation(title: "\(header)")
        }
    }
}

nonisolated struct StatementColumnQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [StatementColumnEntity] {
        identifiers.compactMap { identifier in
            let parts = identifier.components(separatedBy: "\u{1}")
            guard parts.count == 3, let index = Int(parts[0]) else { return nil }
            return StatementColumnEntity(index: index, header: parts[1], sampleValue: parts[2].isEmpty ? nil : parts[2])
        }
    }
}
