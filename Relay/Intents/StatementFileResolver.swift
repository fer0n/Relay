//
//  StatementFileResolver.swift
//  Relay
//
//  CSV/QIF statement parsing shared by both import intents and the share-sheet
//  flow: turns any StatementFileSource into [ImportedStatementRow], asking the
//  "which column is X" questions each caller needs but caching the answers in
//  FileImportConfigStore per distinct header/QIF type.
//
//  The requestDisambiguation calls stay intent-local, since each intent has its
//  own `@Parameter` projections, and are passed in here as ask closures.
//

import AppIntents
import Foundation
import UniformTypeIdentifiers

nonisolated enum StatementImportError: Error {
    case unsupportedFileType
    case invalidFile(reason: String)
}

nonisolated enum StatementFileResolver {
    typealias ColumnAsk = (_ candidates: [StatementColumnEntity], _ dialog: String) async throws -> StatementColumnEntity
    typealias DateFormatAsk = (_ candidates: [DateFormatEntity], _ dialog: String) async throws -> DateFormatEntity

    /// Wires the five interactive `@Parameter` fields to `resolveRows` the way both
    /// import intents want: use a pre-set value, else ask live. Callers pass the
    /// projected values (`$dateColumn`, …) — `IntentParameter` is a reference type,
    /// so the closures built here stay bound to the running intent.
    static func resolveRows(
        file: some StatementFileSource,
        config: inout FileImportConfig,
        dateColumn: IntentParameter<StatementColumnEntity?>,
        payeeColumn: IntentParameter<StatementColumnEntity?>,
        memoColumn: IntentParameter<StatementColumnEntity?>,
        amountColumn: IntentParameter<StatementColumnEntity?>,
        dateFormat: IntentParameter<DateFormatEntity?>
    ) async throws -> [ImportedStatementRow] {
        try await resolveRows(
            file: file,
            config: &config,
            askDateColumn: { candidates, dialog in
                if let value = dateColumn.wrappedValue { return value }
                return try await dateColumn.requestDisambiguation(among: candidates, dialog: IntentDialog(stringLiteral: dialog))
            },
            askPayeeColumn: { candidates, dialog in
                if let value = payeeColumn.wrappedValue { return value }
                return try await payeeColumn.requestDisambiguation(among: candidates, dialog: IntentDialog(stringLiteral: dialog))
            },
            askMemoColumn: { candidates, dialog in
                if let value = memoColumn.wrappedValue { return value }
                return try await memoColumn.requestDisambiguation(among: candidates, dialog: IntentDialog(stringLiteral: dialog))
            },
            askAmountColumn: { candidates, dialog in
                if let value = amountColumn.wrappedValue { return value }
                return try await amountColumn.requestDisambiguation(among: candidates, dialog: IntentDialog(stringLiteral: dialog))
            },
            askDateFormat: { candidates, dialog in
                if let value = dateFormat.wrappedValue { return value }
                return try await dateFormat.requestDisambiguation(among: candidates, dialog: IntentDialog(stringLiteral: dialog))
            }
        )
    }

    static func resolveRows(
        file: some StatementFileSource,
        config: inout FileImportConfig,
        askDateColumn: ColumnAsk,
        askPayeeColumn: ColumnAsk,
        askMemoColumn: ColumnAsk,
        askAmountColumn: ColumnAsk,
        askDateFormat: DateFormatAsk
    ) async throws -> [ImportedStatementRow] {
        guard let kind = detectKind(for: file) else {
            throw StatementImportError.unsupportedFileType
        }
        switch kind {
        case .csv:
            return try await resolveCSVRows(
                file: file,
                config: &config,
                askDateColumn: askDateColumn,
                askPayeeColumn: askPayeeColumn,
                askMemoColumn: askMemoColumn,
                askAmountColumn: askAmountColumn,
                askDateFormat: askDateFormat
            )
        case .qif:
            return try await resolveQIFRows(file: file, config: &config, askDateFormat: askDateFormat)
        }
    }

    /// The extension is the primary signal, but some file providers report
    /// `IntentFile.filename` as the document's *display name*, which iOS strips the
    /// extension from — so a real "Buchungsliste.csv" can arrive as just
    /// "Buchungsliste". Falls back to the UTType, then sniffs the content.
    static func detectKind(for file: some StatementFileSource) -> StatementFileKind? {
        if let kind = StatementFileKind(filename: file.filename) {
            return kind
        }
        if let type = file.type, type.conforms(to: .commaSeparatedText) {
            return .csv
        }
        if looksLikeQIF(file.data) {
            return .qif
        }
        if looksLikeCSV(file.data) {
            return .csv
        }
        return nil
    }

    // MARK: - CSV

    private static func resolveCSVRows(
        file: some StatementFileSource,
        config: inout FileImportConfig,
        askDateColumn: ColumnAsk,
        askPayeeColumn: ColumnAsk,
        askMemoColumn: ColumnAsk,
        askAmountColumn: ColumnAsk,
        askDateFormat: DateFormatAsk
    ) async throws -> [ImportedStatementRow] {
        let table: CSVStatementParser.Table
        do {
            table = try CSVStatementParser.parse(file.data)
        } catch {
            throw StatementImportError.invalidFile(reason: "no rows could be read from this CSV.")
        }

        let headerKey = FileImportConfig.csvKey(for: table.header)
        let sampleRow = table.rows.first
        let mapping: FileImportConfig.HeaderMapping

        if let cached = config.csvMappings[headerKey] {
            mapping = cached
        } else {
            // Pre-set in the Shortcuts editor to skip the prompt; otherwise the ask
            // closure resolves it live.
            let dateEntity = try await askDateColumn(
                columnCandidates(header: table.header, sampleRow: sampleRow, excluding: []),
                String(localized: "Which column is the transaction date?")
            )
            let payeeEntity = try await askPayeeColumn(
                columnCandidates(header: table.header, sampleRow: sampleRow, excluding: [dateEntity.index]),
                String(localized: "Which column is the payee?")
            )
            let memoEntity = try await askMemoColumn(
                columnCandidates(header: table.header, sampleRow: sampleRow, excluding: [dateEntity.index, payeeEntity.index]),
                String(localized: "Which column is the memo?")
            )
            let amountEntity = try await askAmountColumn(
                columnCandidates(
                    header: table.header, sampleRow: sampleRow,
                    excluding: [dateEntity.index, payeeEntity.index, memoEntity.index]
                ),
                String(localized: "Which column is the amount?")
            )

            let dateSamples = distinctSamples(table.rows.map { $0.indices.contains(dateEntity.index) ? $0[dateEntity.index] : "" })
            let resolvedFormat = try await resolveDateFormat(samples: dateSamples, askDateFormat: askDateFormat)

            mapping = FileImportConfig.HeaderMapping(
                dateColumn: dateEntity.index,
                payeeColumn: payeeEntity.index,
                memoColumn: memoEntity.index,
                amountColumn: amountEntity.index,
                dateFormat: resolvedFormat
            )
            config.csvMappings[headerKey] = mapping
            try? FileImportConfigStore.save(config)
        }

        return table.rows.compactMap { fields in
            guard
                mapping.dateColumn < fields.count,
                mapping.payeeColumn < fields.count,
                mapping.amountColumn < fields.count,
                let date = DateFormatDetector.parse(fields[mapping.dateColumn], format: mapping.dateFormat),
                let amount = try? AmountParser.parse(fields[mapping.amountColumn])
            else { return nil }
            let memo = mapping.memoColumn < fields.count ? fields[mapping.memoColumn] : nil
            return ImportedStatementRow(date: date, payeeName: fields[mapping.payeeColumn], memo: memo, amount: amount)
        }
    }

    // MARK: - QIF

    private static func resolveQIFRows(
        file: some StatementFileSource,
        config: inout FileImportConfig,
        askDateFormat: DateFormatAsk
    ) async throws -> [ImportedStatementRow] {
        let table: QIFTable
        do {
            table = try QIFStatementParser.parse(file.data)
        } catch {
            throw StatementImportError.invalidFile(reason: "no transactions could be read from this QIF file.")
        }

        let typeKey = table.typeKey ?? "default"
        let dateFormatString: String
        if let cached = config.qifDateFormats[typeKey] {
            dateFormatString = cached
        } else {
            let samples = distinctSamples(table.records.map(\.date))
            dateFormatString = try await resolveDateFormat(samples: samples, askDateFormat: askDateFormat)
            config.qifDateFormats[typeKey] = dateFormatString
            try? FileImportConfigStore.save(config)
        }

        return table.records.compactMap { record in
            guard
                let date = DateFormatDetector.parse(record.date, format: dateFormatString),
                let amount = try? AmountParser.parse(record.amount)
            else { return nil }
            return ImportedStatementRow(date: date, payeeName: record.payeeName ?? "", memo: record.memo, amount: amount)
        }
    }

    // MARK: - Shared helpers

    private static func looksLikeQIF(_ data: Data) -> Bool {
        guard let text = String(data: data.prefix(32), encoding: .utf8) ?? String(data: data.prefix(32), encoding: .isoLatin1) else {
            return false
        }
        return text.hasPrefix("!Type")
    }

    private static func looksLikeCSV(_ data: Data) -> Bool {
        guard
            let text = String(data: data.prefix(512), encoding: .utf8) ?? String(data: data.prefix(512), encoding: .isoLatin1),
            let firstLine = text.split(separator: "\n", maxSplits: 1).first
        else { return false }
        return firstLine.contains(",") || firstLine.contains(";") || firstLine.contains("\t")
    }

    private static func resolveDateFormat(samples: [String], askDateFormat: DateFormatAsk) async throws -> String {
        guard !samples.isEmpty else {
            throw StatementImportError.invalidFile(reason: "no date values were found to detect a format from.")
        }
        switch DateFormatDetector.detect(samples: samples) {
        case .detected(let format):
            return format
        case .needsDisambiguation(let candidates):
            let entities = candidates.map { format -> DateFormatEntity in
                let preview = DateFormatDetector.parse(samples[0], format: format)?.formatted(date: .abbreviated, time: .omitted)
                return DateFormatEntity(format: format, parsedPreview: preview)
            }
            let resolved = try await askDateFormat(entities, String(localized: "What date format is \(samples[0])?"))
            return resolved.format
        }
    }

    private static func columnCandidates(header: [String], sampleRow: [String]?, excluding usedIndices: [Int]) -> [StatementColumnEntity] {
        let used = Set(usedIndices)
        return header.enumerated().compactMap { index, name in
            guard !used.contains(index) else { return nil }
            let sample = (sampleRow != nil && index < sampleRow!.count) ? sampleRow![index] : nil
            return StatementColumnEntity(index: index, header: name, sampleValue: sample)
        }
    }

    private static func distinctSamples(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values where !value.isEmpty {
            if seen.insert(value).inserted {
                result.append(value)
                if result.count >= 5 { break }
            }
        }
        return result
    }
}
