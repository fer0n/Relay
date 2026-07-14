//
//  ImportYNABFileIntent.swift
//  Hazel
//
//  Siri/Shortcuts equivalent of the "YNAB File Import" Shortcut being
//  replaced (see docs/project-goals.md and ~/Downloads/YNAB Toolkit.txt,
//  the Pythonista script it called into). Reads a bank statement (.csv or
//  .qif), asks the same "which column is X" / "what date format is this"
//  questions the original did — but only the first time for a given
//  header/QIF type, since FileImportConfigStore caches the answer — then
//  bulk-creates the resulting transactions in one YNAB API call.
//
//  Unlike AddYNABTransactionIntent's `requestValue` (which throws a
//  sentinel error to restart perform() from the top), `requestDisambiguation`
//  is `async throws -> Value.ValueType`: it awaits the user's answer
//  in-place and returns it, so column/date-format resolution below just
//  reads top-to-bottom without any restart.
//

import AppIntents
import UniformTypeIdentifiers

nonisolated struct ImportYNABFileIntent: AppIntent {
    static let title: LocalizedStringResource = "Import File to YNAB"
    static let description = IntentDescription("Imports transactions from a bank statement file (CSV or QIF) into YNAB.")

    // No system UTType exists for .qif, and the AppIntents metadata build
    // step only accepts literal, statically-known UTType members here (a
    // runtime `UTType(filenameExtension:)` call fails that step) — `.data`
    // is a broad enough catch-all that .qif files still pass the picker's
    // filter; StatementFileKind rejects anything else at runtime.
    @Parameter(title: "File", supportedContentTypes: [.commaSeparatedText, .data])
    var file: IntentFile

    @Parameter(title: "Account")
    var account: YNABAccountEntity

    @Parameter(title: "Import Memos", default: true)
    var importMemos: Bool

    // Resolved interactively via requestDisambiguation, only when this
    // file's CSV header (or QIF account type) hasn't been imported before —
    // see FileImportConfigStore. Not surfaced in parameterSummary since
    // they're only meaningful mid-run, tied to one specific file.
    @Parameter(title: "Date Column")
    var dateColumn: StatementColumnEntity?
    @Parameter(title: "Payee Column")
    var payeeColumn: StatementColumnEntity?
    @Parameter(title: "Memo Column")
    var memoColumn: StatementColumnEntity?
    @Parameter(title: "Amount Column")
    var amountColumn: StatementColumnEntity?
    @Parameter(title: "Date Format")
    var dateFormat: DateFormatEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Import \(\.$file) to \(\.$account)") {
            \.$importMemos
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let token = YNABAuthService.currentAccessToken else {
            throw YNABIntentError.notAuthenticated
        }

        let filename = file.filename
        guard let kind = detectKind(for: file) else {
            throw YNABIntentError.unsupportedFileType
        }

        var config = FileImportConfigStore.load()
        let rows: [ImportedStatementRow]

        switch kind {
        case .csv:
            rows = try await resolveCSVRows(config: &config)
        case .qif:
            rows = try await resolveQIFRows(config: &config)
        }

        let built = StatementTransactionBuilder.build(from: rows, accountId: account.id, importMemos: importMemos)
        guard !built.transactions.isEmpty else {
            return .result(dialog: "No transactions found to import from \(filename).")
        }

        do {
            let bulkResult = try await YNABService.createTransactions(built.transactions, token: token)
            return .result(dialog: IntentDialog(stringLiteral: summary(for: bulkResult)))
        } catch {
            throw YNABIntentError.from(error)
        }
    }

    // MARK: - CSV

    private func resolveCSVRows(config: inout FileImportConfig) async throws -> [ImportedStatementRow] {
        let table: CSVStatementParser.Table
        do {
            table = try CSVStatementParser.parse(file.data)
        } catch {
            throw YNABIntentError.invalidFile(reason: "no rows could be read from this CSV.")
        }

        let headerKey = FileImportConfig.csvKey(for: table.header)
        let sampleRow = table.rows.first
        let mapping: FileImportConfig.HeaderMapping

        if let cached = config.csvMappings[headerKey] {
            mapping = cached
        } else {
            // A power user can pre-set these in the Shortcuts editor to
            // skip the prompt entirely; otherwise ask.
            let dateEntity: StatementColumnEntity
            if let dateColumn {
                dateEntity = dateColumn
            } else {
                dateEntity = try await $dateColumn.requestDisambiguation(
                    among: columnCandidates(header: table.header, sampleRow: sampleRow, excluding: []),
                    dialog: "Which column is the transaction date?"
                )
            }
            let payeeEntity: StatementColumnEntity
            if let payeeColumn {
                payeeEntity = payeeColumn
            } else {
                payeeEntity = try await $payeeColumn.requestDisambiguation(
                    among: columnCandidates(header: table.header, sampleRow: sampleRow, excluding: [dateEntity.index]),
                    dialog: "Which column is the payee?"
                )
            }
            let memoEntity: StatementColumnEntity
            if let memoColumn {
                memoEntity = memoColumn
            } else {
                memoEntity = try await $memoColumn.requestDisambiguation(
                    among: columnCandidates(header: table.header, sampleRow: sampleRow, excluding: [dateEntity.index, payeeEntity.index]),
                    dialog: "Which column is the memo?"
                )
            }
            let amountEntity: StatementColumnEntity
            if let amountColumn {
                amountEntity = amountColumn
            } else {
                amountEntity = try await $amountColumn.requestDisambiguation(
                    among: columnCandidates(
                        header: table.header, sampleRow: sampleRow,
                        excluding: [dateEntity.index, payeeEntity.index, memoEntity.index]
                    ),
                    dialog: "Which column is the amount?"
                )
            }

            let dateSamples = distinctSamples(table.rows.map { $0.indices.contains(dateEntity.index) ? $0[dateEntity.index] : "" })
            let resolvedFormat = try await resolveDateFormat(samples: dateSamples)

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

    private func resolveQIFRows(config: inout FileImportConfig) async throws -> [ImportedStatementRow] {
        let table: QIFTable
        do {
            table = try QIFStatementParser.parse(file.data)
        } catch {
            throw YNABIntentError.invalidFile(reason: "no transactions could be read from this QIF file.")
        }

        let typeKey = table.typeKey ?? "default"
        let dateFormatString: String
        if let cached = config.qifDateFormats[typeKey] {
            dateFormatString = cached
        } else {
            let samples = distinctSamples(table.records.map(\.date))
            dateFormatString = try await resolveDateFormat(samples: samples)
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

    /// Filename extension is the primary signal, but some sources (notably
    /// files picked via Shortcuts from certain cloud/file providers) report
    /// `IntentFile.filename` as the document's *display name*, which iOS
    /// hides the extension from when "Show all filename extensions" is off
    /// — so a real "Buchungsliste.csv" can arrive as just "Buchungsliste".
    /// Falls back to the file's UTType, then sniffs the content itself.
    private func detectKind(for file: IntentFile) -> StatementFileKind? {
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

    private func looksLikeQIF(_ data: Data) -> Bool {
        guard let text = String(data: data.prefix(32), encoding: .utf8) ?? String(data: data.prefix(32), encoding: .isoLatin1) else {
            return false
        }
        return text.hasPrefix("!Type")
    }

    private func looksLikeCSV(_ data: Data) -> Bool {
        guard
            let text = String(data: data.prefix(512), encoding: .utf8) ?? String(data: data.prefix(512), encoding: .isoLatin1),
            let firstLine = text.split(separator: "\n", maxSplits: 1).first
        else { return false }
        return firstLine.contains(",") || firstLine.contains(";") || firstLine.contains("\t")
    }

    private func resolveDateFormat(samples: [String]) async throws -> String {
        guard !samples.isEmpty else {
            throw YNABIntentError.invalidFile(reason: "no date values were found to detect a format from.")
        }
        switch DateFormatDetector.detect(samples: samples) {
        case .detected(let format):
            return format
        case .needsDisambiguation(let candidates):
            if let dateFormat {
                return dateFormat.format
            }
            let entities = candidates.map { format -> DateFormatEntity in
                let preview = DateFormatDetector.parse(samples[0], format: format)?.formatted(date: .abbreviated, time: .omitted)
                return DateFormatEntity(format: format, parsedPreview: preview)
            }
            let resolved = try await $dateFormat.requestDisambiguation(
                among: entities,
                dialog: "What date format is \(samples[0])?"
            )
            return resolved.format
        }
    }

    private func columnCandidates(header: [String], sampleRow: [String]?, excluding usedIndices: [Int]) -> [StatementColumnEntity] {
        let used = Set(usedIndices)
        return header.enumerated().compactMap { index, name in
            guard !used.contains(index) else { return nil }
            let sample = (sampleRow != nil && index < sampleRow!.count) ? sampleRow![index] : nil
            return StatementColumnEntity(index: index, header: name, sampleValue: sample)
        }
    }

    private func distinctSamples(_ values: [String]) -> [String] {
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

    /// Mirrors the Python original's `handle_response`: the single
    /// transaction's amount/payee if exactly one was created, otherwise a
    /// count, plus a duplicate count if YNAB's own `import_id` dedup found any.
    private func summary(for result: YNABBulkImportResult) -> String {
        var parts: [String] = []
        if result.transactions.count == 1, let transaction = result.transactions.first {
            let amount = Double(transaction.amount) / 1000
            let formattedAmount = amount.formatted(.number.precision(.fractionLength(2)))
            parts.append("\(formattedAmount), \(transaction.payeeName ?? "")")
        } else if result.transactions.count > 1 {
            parts.append("\(result.transactions.count) transactions created")
        } else {
            parts.append("No new transactions created")
        }
        if !result.duplicateImportIds.isEmpty {
            parts.append("\(result.duplicateImportIds.count) duplicates found")
        }
        return parts.joined(separator: ". ")
    }
}
