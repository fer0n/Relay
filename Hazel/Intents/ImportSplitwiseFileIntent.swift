//
//  ImportSplitwiseFileIntent.swift
//  Hazel
//
//  Splitwise counterpart to ImportYNABFileIntent: reads a bank statement
//  (.csv or .qif) via the same StatementFileResolver (so a CSV header
//  already mapped for the YNAB import isn't re-asked here), resolves which
//  friend to split with, then stages the parsed rows for
//  SharedFileImportView instead of creating anything itself —
//  AppIntents' requestDisambiguation only resolves a single value at a
//  time, so there's no supported way to let the user multi-select which of
//  N parsed transactions to split from inside perform(). The actual
//  multi-select + expense creation happens in Hazel's own UI.
//

import AppIntents
import Foundation
import UniformTypeIdentifiers

nonisolated struct ImportSplitwiseFileIntent: AppIntent {
    static let title: LocalizedStringResource = "Import File to Splitwise"
    static let description = IntentDescription(
        "Parses a bank statement file (CSV or QIF) so you can pick which transactions to split equally with a Splitwise friend in Hazel."
    )

    // The whole point of this intent is the review screen it hands off to —
    // there's nothing useful left to tell the user in a Shortcuts dialog, so
    // bring Hazel to the foreground and go straight there instead (see the
    // DraftNotificationRouter.pendingSplitwiseImport set below).
    static var supportedModes: IntentModes { .foreground(.immediate) }

    @Parameter(title: "File", supportedContentTypes: [.commaSeparatedText, .data])
    var file: IntentFile

    @Parameter(title: "Split With")
    var friend: SplitwiseFriendEntity?

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
        Summary("Import \(\.$file) to Splitwise") {
            \.$friend
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard SplitwiseAuthService.currentAccessToken != nil else {
            throw SplitwiseIntentError.notAuthenticated
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
            throw SplitwiseIntentError.from(error)
        }

        // Explicit override → app-configured default → live ask, same
        // fallback order AddWalletTransactionToYNABIntent uses for its
        // Splitwise friend.
        let resolvedFriend: SplitwiseFriendEntity
        if let friend {
            resolvedFriend = friend
        } else if let defaultFriend = SplitwiseDefaultFriendStore.load() {
            resolvedFriend = SplitwiseFriendEntity(id: defaultFriend.id, firstName: defaultFriend.firstName, fullName: defaultFriend.fullName)
        } else {
            let friends = try await SplitwiseFriendEntity.defaultQuery.suggestedEntities()
            resolvedFriend = try await $friend.requestDisambiguation(among: friends, dialog: "Split with which Splitwise friend?")
        }

        let candidateRows = FileImportRowBuilder.build(from: rows)
        guard !candidateRows.isEmpty else {
            return .result(dialog: "No transactions found to import from \(filename).")
        }

        do {
            try FileImportStagingStore.save(FileImportStaging(
                destination: .splitwise,
                rows: candidateRows,
                selectedIDs: Set(candidateRows.map(\.id)),
                sourceFilename: filename,
                importedAt: Date(),
                friendId: resolvedFriend.id,
                friendFirstName: resolvedFriend.firstName,
                friendFullName: resolvedFriend.fullName
            ))
        } catch {
            throw SplitwiseIntentError.requestFailed
        }

        await MainActor.run {
            DraftNotificationRouter.shared.pendingSplitwiseImport = true
        }

        return .result(dialog: "Parsed \(candidateRows.count) transactions from \(filename).")
    }
}
