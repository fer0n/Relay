//
//  ImportLedgerFileIntent.swift
//  Relay
//
//  Ledger counterpart to ImportYNABFileIntent: reads a bank statement
//  (.csv or .qif) via the same StatementFileResolver (so a CSV header
//  already mapped for the YNAB import isn't re-asked here), resolves which
//  ledger to split with, then stages the parsed rows for
//  SharedFileImportView instead of creating anything itself —
//  AppIntents' requestDisambiguation only resolves a single value at a
//  time, so there's no supported way to let the user multi-select which of
//  N parsed transactions to split from inside perform(). The actual
//  multi-select + expense creation happens in Relay's own UI.
//

import AppIntents
import Foundation
import UniformTypeIdentifiers

struct ImportLedgerFileIntent: AppIntent {
    static let title: LocalizedStringResource = "Import File to Split"
    static let description = IntentDescription(
        "Parses a bank statement file (CSV or QIF) so you can pick which transactions to split on a shared iCloud ledger in Relay."
    )

    // The whole point of this intent is the review screen it hands off to —
    // there's nothing useful left to tell the user in a Shortcuts dialog, so
    // bring Relay to the foreground and go straight there instead (see the
    // DraftNotificationRouter.pendingSplitImport set below).
    static var supportedModes: IntentModes { .foreground(.immediate) }

    @Parameter(title: "File", supportedContentTypes: [.commaSeparatedText, .data])
    var file: IntentFile

    @Parameter(title: "Split With")
    var friend: SplitTargetEntity?

    // Resolved interactively via requestDisambiguation, only when this
    // file's CSV header (or QIF account type) hasn't been imported before —
    // see FileImportConfigStore, shared with ImportYNABFileIntent. Not
    // surfaced in parameterSummary since they're only meaningful mid-run,
    // tied to one specific file.
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
        Summary("Import \(\.$file) to split") {
            \.$friend
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard await SplitAvailability.canSplit else {
            throw LedgerExpenseError.validation("Create a shared ledger in Relay first.")
        }

        let filename = file.filename
        var config = FileImportConfigStore.load()
        let rows: [ImportedStatementRow]
        do {
            rows = try await StatementFileResolver.resolveRows(
                file: file,
                config: &config,
                dateColumn: $dateColumn,
                payeeColumn: $payeeColumn,
                memoColumn: $memoColumn,
                amountColumn: $amountColumn,
                dateFormat: $dateFormat
            )
        } catch {
            throw error
        }

        // Explicit override → app-configured default → live ask, the same
        // fallback order AddWalletTransactionToYNABIntent uses.
        let resolvedTarget: SplitTargetEntity
        if let friend {
            resolvedTarget = friend
        } else if let defaultTarget = DefaultSplitTargetStore.load() {
            resolvedTarget = SplitTargetEntity(cachedTarget: defaultTarget)
        } else {
            let targets = try await SplitTargetEntity.defaultQuery.suggestedEntities()
            resolvedTarget = try await $friend.requestDisambiguation(among: targets, dialog: "Split on which ledger?")
        }

        let candidateRows = FileImportRowBuilder.build(from: rows)
        guard !candidateRows.isEmpty else {
            return .result(dialog: "No transactions found to import from \(filename).")
        }

        do {
            try FileImportStagingStore.save(FileImportStaging(
                destination: .split,
                rows: candidateRows,
                selectedIDs: Set(candidateRows.map(\.id)),
                sourceFilename: filename,
                importedAt: Date(),
                ledgerZoneName: resolvedTarget.zoneName,
                targetFirstName: resolvedTarget.firstName,
                targetFullName: resolvedTarget.fullName,
                ledgerParticipantID: resolvedTarget.participantID
            ))
        } catch {
            throw LedgerExpenseError.writeFailed(nil)
        }

        await MainActor.run {
            DraftNotificationRouter.shared.pendingSplitImport = true
        }

        return .result(dialog: "Parsed \(candidateRows.count) transactions from \(filename).")
    }
}
