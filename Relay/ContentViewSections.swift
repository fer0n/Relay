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

/// The pinned Splitwise balance card, or the faint logo watermark when no
/// default friend is configured.
struct ContentBalanceHeaderSection: View {
    let friend: SplitwiseFriend?
    let lastRefreshedAt: Date?
    let onTap: () -> Void

    var body: some View {
        Section {
            if let friend {
                SplitwiseBalanceGrid(friend: friend, lastRefreshedAt: lastRefreshedAt, onTap: onTap)
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

/// The always-present navigation rows (Templates / Settings), plus a
/// "Splitwise" section for Balances and Activity. That second section is
/// omitted wholesale — header included — when Splitwise isn't connected:
/// without a token both destinations are empty (an empty grid, an empty
/// feed), and gating only the rows would leave a titled section with nothing
/// under it.
struct ContentQuickLinksSection: View {
    let splitwiseConnected: Bool

    var body: some View {
        Section {
            NavigationLink(value: ContentRoute.templates) {
                RowLabel(title: "Templates", systemImage: "doc.on.doc")
            }
            NavigationLink(value: ContentRoute.settings) {
                RowLabel(title: "Settings", systemImage: "switch.2")
            }
        }
        .cardRowBackground()

        if splitwiseConnected {
            Section("Splitwise") {
                NavigationLink(value: ContentRoute.splitwiseBalances) {
                    RowLabel(title: "Balances", systemImage: "person.2.fill")
                }
                NavigationLink(value: ContentRoute.splitwiseActivity) {
                    RowLabel(title: "Activity", systemImage: "bell.fill")
                }
            }
            .cardRowBackground()
        }
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
                .matchedTransitionSource(id: draft.id, in: namespace)
                .swipeActions {
                    Button(role: .destructive) {
                        onDismiss(draft)
                    } label: {
                        Image(systemName: "trash.fill")
                    }
                }
            }
            if hasMore {
                NavigationLink(value: ContentRoute.transactionDrafts) {
                    RowLabel(title: "Show All", systemImage: "square.and.pencil")
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

    var body: some View {
        Section("Recent") {
            ForEach(history) { entry in
                Button {
                    onSelect(entry)
                } label: {
                    TransactionSummaryRow(
                        service: entry.service,
                        secondaryService: entry.secondaryService,
                        date: entry.createdAt,
                        title: entry.title,
                        amount: entry.formattedAmount,
                        detail: entry.detail,
                        suppressedCount: entry.suppressed.count
                    )
                }
                .cardRowBackground()
                .matchedTransitionSource(id: entry.id, in: namespace)
                .contextMenu {
                    Button {
                        onReAdd(entry)
                    } label: {
                        Label("Re-add", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
    }
}
