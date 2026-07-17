//
//  ColumnMappingPrompt.swift
//  Hazel
//
//  SwiftUI stand-in for AppIntents' requestDisambiguation, used by
//  SharedFileImportView to satisfy StatementFileResolver.resolveRows'
//  ask-closures when a bank statement's header/date format hasn't been seen
//  before (see FileImportConfigStore) — presents one sheet at a time and
//  resumes the async ask-closure once the user taps a candidate.
//

import AppIntents
import SwiftUI

@MainActor
@Observable
final class ColumnMappingPrompt {
    struct ColumnRequest {
        let candidates: [StatementColumnEntity]
        let dialog: String
        let continuation: CheckedContinuation<StatementColumnEntity, Error>
    }

    struct DateFormatRequest {
        let candidates: [DateFormatEntity]
        let dialog: String
        let continuation: CheckedContinuation<DateFormatEntity, Error>
    }

    var columnRequest: ColumnRequest?
    var dateFormatRequest: DateFormatRequest?

    func askColumn(_ candidates: [StatementColumnEntity], dialog: String) async throws -> StatementColumnEntity {
        try await withCheckedThrowingContinuation { continuation in
            columnRequest = ColumnRequest(candidates: candidates, dialog: dialog, continuation: continuation)
        }
    }

    func askDateFormat(_ candidates: [DateFormatEntity], dialog: String) async throws -> DateFormatEntity {
        try await withCheckedThrowingContinuation { continuation in
            dateFormatRequest = DateFormatRequest(candidates: candidates, dialog: dialog, continuation: continuation)
        }
    }

    /// Wires this prompt's `askColumn`/`askDateFormat` into a
    /// `StatementFileResolver.resolveRows` call — shared by both
    /// destinations of SharedFileImportView so the five ask-closures only
    /// need writing once.
    func resolveRows(file: some StatementFileSource, config: inout FileImportConfig) async throws -> [ImportedStatementRow] {
        try await StatementFileResolver.resolveRows(
            file: file,
            config: &config,
            askDateColumn: { candidates, dialog in try await self.askColumn(candidates, dialog: dialog) },
            askPayeeColumn: { candidates, dialog in try await self.askColumn(candidates, dialog: dialog) },
            askMemoColumn: { candidates, dialog in try await self.askColumn(candidates, dialog: dialog) },
            askAmountColumn: { candidates, dialog in try await self.askColumn(candidates, dialog: dialog) },
            askDateFormat: { candidates, dialog in try await self.askDateFormat(candidates, dialog: dialog) }
        )
    }

    fileprivate func resolveColumn(_ entity: StatementColumnEntity) {
        guard let request = columnRequest else { return }
        columnRequest = nil
        request.continuation.resume(returning: entity)
    }

    fileprivate func cancelColumn() {
        guard let request = columnRequest else { return }
        columnRequest = nil
        request.continuation.resume(throwing: CancellationError())
    }

    fileprivate func resolveDateFormat(_ entity: DateFormatEntity) {
        guard let request = dateFormatRequest else { return }
        dateFormatRequest = nil
        request.continuation.resume(returning: entity)
    }

    fileprivate func cancelDateFormat() {
        guard let request = dateFormatRequest else { return }
        dateFormatRequest = nil
        request.continuation.resume(throwing: CancellationError())
    }
}

/// One tappable candidate list, reused for both the column-picker and
/// date-format-picker sheets — only the row content and dialog text differ.
private struct ColumnMappingSheet<Entity: Identifiable, RowContent: View>: View {
    let dialog: String
    let candidates: [Entity]
    let onSelect: (Entity) -> Void
    @ViewBuilder let row: (Entity) -> RowContent

    var body: some View {
        NavigationStack {
            List(candidates) { candidate in
                Button {
                    onSelect(candidate)
                } label: {
                    row(candidate)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .cardRowBackground()
            }
            .themedList(background: .sheetBackgroundColor)
            .navigationTitle(dialog)
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
    }
}

extension View {
    /// Attach once per screen that calls `StatementFileResolver.resolveRows`
    /// with `prompt`'s `askColumn`/`askDateFormat` as its ask-closures.
    /// Dismissing either sheet without picking a candidate (swipe-to-dismiss)
    /// throws a `CancellationError` back into `resolveRows`.
    func columnMappingPrompt(_ prompt: ColumnMappingPrompt) -> some View {
        self
            .sheet(isPresented: Binding(
                get: { prompt.columnRequest != nil },
                set: { if !$0 { prompt.cancelColumn() } }
            )) {
                if let request = prompt.columnRequest {
                    ColumnMappingSheet(dialog: request.dialog, candidates: request.candidates) { entity in
                        prompt.resolveColumn(entity)
                    } row: { candidate in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.header)
                            if let sample = candidate.sampleValue, !sample.isEmpty {
                                Text(sample).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .sheet(isPresented: Binding(
                get: { prompt.dateFormatRequest != nil },
                set: { if !$0 { prompt.cancelDateFormat() } }
            )) {
                if let request = prompt.dateFormatRequest {
                    ColumnMappingSheet(dialog: request.dialog, candidates: request.candidates) { entity in
                        prompt.resolveDateFormat(entity)
                    } row: { candidate in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.parsedPreview ?? candidate.format)
                            if candidate.parsedPreview != nil {
                                Text(candidate.format).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
    }
}
