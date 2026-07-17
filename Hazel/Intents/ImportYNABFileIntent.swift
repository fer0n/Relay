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
        guard let token = await YNABAuthService.validAccessToken() else {
            throw YNABIntentError.notAuthenticated
        }

        let filename = file.filename
        var config = FileImportConfigStore.load()
        let rows: [ImportedStatementRow]
        do {
            rows = try await StatementFileResolver.resolveRows(
                file: file,
                config: &config,
                askDateColumn: { candidates, dialog in
                    if let dateColumn { return dateColumn }
                    return try await $dateColumn.requestDisambiguation(among: candidates, dialog: IntentDialog(stringLiteral: dialog))
                },
                askPayeeColumn: { candidates, dialog in
                    if let payeeColumn { return payeeColumn }
                    return try await $payeeColumn.requestDisambiguation(among: candidates, dialog: IntentDialog(stringLiteral: dialog))
                },
                askMemoColumn: { candidates, dialog in
                    if let memoColumn { return memoColumn }
                    return try await $memoColumn.requestDisambiguation(among: candidates, dialog: IntentDialog(stringLiteral: dialog))
                },
                askAmountColumn: { candidates, dialog in
                    if let amountColumn { return amountColumn }
                    return try await $amountColumn.requestDisambiguation(among: candidates, dialog: IntentDialog(stringLiteral: dialog))
                },
                askDateFormat: { candidates, dialog in
                    if let dateFormat { return dateFormat }
                    return try await $dateFormat.requestDisambiguation(among: candidates, dialog: IntentDialog(stringLiteral: dialog))
                }
            )
        } catch {
            throw YNABIntentError.from(error)
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

    /// Mirrors the Python original's `handle_response`: the single
    /// transaction's amount/payee if exactly one was created, otherwise a
    /// count, plus a duplicate count if YNAB's own `import_id` dedup found any.
    private func summary(for result: YNABBulkImportResult) -> String {
        var parts: [String] = []
        if result.transactions.count == 1, let transaction = result.transactions.first {
            let amount = Double(transaction.amount) / 1000
            let formattedAmount = amount.asMoneyString
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
