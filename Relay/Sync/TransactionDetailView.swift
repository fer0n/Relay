//
//  TransactionDetailView.swift
//  Relay
//
//  Unified detail screen for a single transaction, reached two ways:
//
//  - `.draft(id:)` — a tapped "Continue Adding Transaction" notification (or
//    a draft row in TransactionDraftsView): loads the draft by id and routes
//    to the editable continue flow (ContinueWalletTransactionView), or
//    explains there's nothing left to do if it's already been resolved
//    (completed elsewhere, or dismissed) since the notification fired.
//  - `.history(_:)` — a tapped row in ContentView's "Recent" list: a
//    read-only summary of an already-created YNAB transaction and/or
//    Splitwise expense. No editing — re-adding stays on the row's context
//    menu.
//

import SwiftUI

struct TransactionDetailView: View {
    enum Source {
        case draft(id: UUID)
        case history(TransactionHistoryEntry)
    }

    let source: Source

    var body: some View {
        switch source {
        case .draft(let id):
            DraftDetailContent(draftId: id)
        case .history(let entry):
            HistoryDetailContent(entry: entry)
        }
    }
}

// MARK: - Draft (editable continue flow)

private struct DraftDetailContent: View {
    let draftId: UUID

    @State private var draft: TransactionDraft?
    @State private var isLoaded = false
    @State private var showDeleteConfirmation = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let draft {
                ContinueWalletTransactionView(draft: draft)
            } else if isLoaded {
                ContentUnavailableView(
                    "Already Handled",
                    systemImage: "checkmark.circle",
                    description: Text("This transaction was already completed or dismissed.")
                )
            } else {
                ProgressView()
            }
        }
        .toolbar {
            if draft != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Image(systemName: "trash.fill")
                    }
                    .confirmationDialog(
                        "Delete this draft?",
                        isPresented: $showDeleteConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("Delete", role: .destructive, action: delete)
                    }
                }
            }
        }
        .task {
            draft = TransactionDraftStore.load().first { $0.id == draftId }
            isLoaded = true
        }
    }

    private func delete() {
        guard let draft else { return }
        TransactionDraftGuard.complete(draft.id)
        dismiss()
    }
}

// MARK: - History (read-only)

private struct HistoryDetailContent: View {
    let entry: TransactionHistoryEntry

    private var titleLabel: LocalizedStringKey {
        entry.service == .ynab ? "Payee" : "Description"
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 4) {
                    Text(entry.formattedAmount)
                        .foregroundStyle(Color.foregroundColor)
                        .fontWeight(.heavy)
                        .font(.system(size: 50))
                        .minimumScaleFactor(0.5)
                    HStack(spacing: 6) {
                        Image(systemName: entry.service.systemImage)
                        if let secondaryService = entry.secondaryService {
                            Image(systemName: secondaryService.systemImage)
                        }
                        Text(entry.title)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    Text("Added \(RelativeDateTimeFormatter().localizedString(for: entry.createdAt, relativeTo: Date()))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.sheetBackgroundColor)

            Section {
                DraftDetailRow(icon: "text.alignleft", title: titleLabel) {
                    Text(entry.title)
                }
                .cardRowBackground()

                if let categoryName = entry.categoryName {
                    DraftDetailRow(icon: "tag.fill", title: "Category") {
                        Text(categoryName)
                    }
                    .cardRowBackground()
                }

                if let accountName = entry.accountName {
                    DraftDetailRow(icon: "creditcard.fill", title: "Account") {
                        Text(accountName)
                    }
                    .cardRowBackground()
                }
            }

            if let splitSummary = entry.splitSummary {
                Section("Split") {
                    DraftDetailRow(icon: "person.2.fill", title: "With") {
                        Text(splitSummary)
                    }
                    .cardRowBackground()
                }
            }
        }
        .themedList(background: .sheetBackgroundColor)
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview("Draft") {
    let draft = TransactionDraft(
        id: UUID(),
        startedAt: Date().addingTimeInterval(-3600),
        payload: .ynabWallet(merchant: "Coffee Shop", amount: 4.50, card: "Visa")
    )
    Color.clear
        .onAppear { try? TransactionDraftStore.save([draft]) }
        .sheet(isPresented: .constant(true)) {
            NavigationStack {
                TransactionDetailView(source: .draft(id: draft.id))
            }
        }
}

#Preview("History") {
    let entry = TransactionHistoryEntry(
        id: UUID(),
        createdAt: Date().addingTimeInterval(-3600),
        summary: "12.34 at Coffee Shop",
        payload: .ynabTransaction(YNABTransactionRequest(
            accountId: "acct",
            date: "2026-07-21",
            amount: -12340,
            payeeName: "Coffee Shop",
            categoryId: nil,
            cleared: "cleared",
            approved: true
        ))
    )
    Color.clear
        .sheet(isPresented: .constant(true)) {
            NavigationStack {
                TransactionDetailView(source: .history(entry))
            }
        }
}
