//
//  ContentViewSections.swift
//  Relay
//
//  The individual List sections of ContentView's main screen, split out as
//  small standalone views so ContentView itself stays focused on state and
//  navigation. Each takes just the data it renders plus closures for the
//  actions that mutate ContentView's state, rather than reaching back into it.
//

import SwiftUI

extension AnyTransition {
    /// Shared by every conditionally-shown row/section on ContentView's main
    /// list so they animate in/out together instead of just popping.
    static let contentRow = AnyTransition.opacity.combined(with: .move(edge: .top))
}

/// The pinned card for the default ledger (set in Settings), or a faint logo
/// watermark when none is.
struct ContentBalanceHeaderSection: View {
    let ledger: Ledger?
    let balances: LedgerBalances
    let currentUserID: String?
    /// Shown on the card as "Last refreshed …".
    let lastRefreshedAt: Date?
    let onTap: () -> Void

    var body: some View {
        Section {
            if let ledger {
                LedgerBalanceGrid(
                    ledger: ledger,
                    balances: balances,
                    currentUserID: currentUserID,
                    lastRefreshedAt: lastRefreshedAt,
                    onTap: onTap
                )
                .padding(.bottom, 8)
            } else {
                Image("Logo")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
                    .opacity(0.2)
                    .frame(maxWidth: 100, maxHeight: 100)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            }
        }
        .listRowSeparator(.hidden)
        .listRowBackground(Color.backgroundColor)
    }
}

/// The always-present navigation rows: Templates, Ledgers, Settings.
struct ContentQuickLinksSection: View {

    var body: some View {
        Section {
            NavigationLink(value: ContentRoute.templates) {
                RowLabel(title: "Templates", systemImage: Const.Symbol.template)
            }
            NavigationLink(value: ContentRoute.ledgers) {
                RowLabel(title: "Ledgers", systemImage: Const.Symbol.ledger)
            }
            NavigationLink(value: ContentRoute.settings) {
                RowLabel(title: "Settings", systemImage: "switch.2")
            }
        }
        .cardRowBackground()

    }
}

/// The most-recent drafts, with a "Show All" link when there are more than
/// fit here. `drafts` is already the trimmed top slice; `hasMore` drives the
/// link.
struct ContentDraftsSection: View {
    let drafts: [TransactionDraft]
    let hasMore: Bool
    let namespace: Namespace.ID
    let onContinue: (TransactionDraft) -> Void
    let onDismiss: (TransactionDraft) -> Void

    var body: some View {
        Section("Drafts") {
            ForEach(drafts) { draft in
                Button {
                    onContinue(draft)
                } label: {
                    TransactionSummaryRow(service: draft.service, date: draft.startedAt, title: draft.merchant, amount: draft.formattedAmount)
                }
                .cardRowBackground()
                .transition(.contentRow)
                .matchedTransitionSource(id: draft.id, in: namespace)
                .swipeActions {
                    Button(role: .destructive) {
                        onDismiss(draft)
                    } label: {
                        Image(systemName: Const.Symbol.delete)
                    }
                }
            }
            if hasMore {
                NavigationLink(value: ContentRoute.transactionDrafts) {
                    RowLabel(title: "Show All", systemImage: Const.Symbol.drafts)
                }
                .cardRowBackground()
            }
        }
    }
}

/// The recently-created transactions, each opening its detail sheet on tap and
/// offering "Re-add" from a context menu.
struct ContentRecentSection: View {
    let history: [TransactionHistoryEntry]
    let namespace: Namespace.ID
    let onSelect: (TransactionHistoryEntry) -> Void
    let onReAdd: (TransactionHistoryEntry) -> Void
    let onDelete: (TransactionHistoryEntry) -> Void

    /// Set by the swipe action's Delete button to gate a confirmation before
    /// actually deleting. The dialog it drives hangs off the section, not the
    /// row — see below.
    @State private var entryPendingDelete: TransactionHistoryEntry?

    var body: some View {
        Section("Recent") {
            ForEach(history) { entry in
                Button {
                    onSelect(entry)
                } label: {
                    TransactionSummaryRow(
                        service: entry.service,
                        secondaryService: entry.secondaryService,
                        date: entry.date,
                        title: entry.title,
                        amount: entry.formattedAmount,
                        detail: entry.detail,
                        suppressedCount: entry.suppressed.count
                    )
                }
                .cardRowBackground()
                // The row itself, not just the section around it: without
                // this, adding a transaction to a list that already had one
                // popped the new row in while everything below it jumped down.
                .transition(.contentRow)
                .matchedTransitionSource(id: entry.id, in: namespace)
                .contextMenu {
                    Button {
                        onReAdd(entry)
                    } label: {
                        Label("Re-add", systemImage: "arrow.clockwise")
                    }
                }
                .swipeActions {
                    Button {
                        entryPendingDelete = entry
                    } label: {
                        Image(systemName: Const.Symbol.delete)
                    }
                    .tint(.red)
                }
            }
        }
        // One dialog for the section, not one per row: attached inside the
        // ForEach it built a modifier and a binding for every entry on
        // screen. Same fix, and the same anchoring reason, as
        // LedgerDetailView's — it stays off the swipe button, which is torn
        // down as the swipe closes.
        .confirmationDialog(
            "Delete this transaction?",
            isPresented: Binding(
                get: { entryPendingDelete != nil },
                set: { if !$0 { entryPendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: entryPendingDelete
        ) { entry in
            Button("Delete", role: .destructive) {
                withAnimation {
                    entryPendingDelete = nil
                    onDelete(entry)
                }
            }
        } message: { _ in
            Text("This will only delete locally, YNAB and your ledgers are unaffected.")
        }
    }
}
