//
//  TransactionDraftsView.swift
//  Relay
//
//  Lists whatever TransactionDraftGuard still considers "started but not
//  finished". Tapping one opens ContinueDraftView as a sheet to actually
//  finish it — the same flow a tapped notification opens — since there's no
//  way to resume the original suspended App Intent perform() call; dismissing
//  one instead just clears the draft and cancels its notification without
//  finishing anything.
//

import SwiftUI

struct TransactionDraftsView: View {
    @State private var drafts: [TransactionDraft] = TransactionDraftStore.load()
    @State private var selectedDraft: TransactionDraft?

    var body: some View {
        List {
            ForEach(drafts) { draft in
                Button {
                    selectedDraft = draft
                } label: {
                    TransactionSummaryRow(service: draft.service, date: draft.startedAt, title: draft.merchant, amount: draft.formattedAmount, showChevron: true)
                }
                .cardRowBackground()
                .swipeActions {
                    Button("Dismiss", role: .destructive) {
                        TransactionDraftGuard.complete(draft.id)
                        drafts.removeAll { $0.id == draft.id }
                    }
                }
            }
        }
        .themedListStyle()
        .background {
            Color.backgroundColor
            if drafts.isEmpty {
                EmptyListBackground(systemName: "square.and.pencil")
            }
        }
        .navigationTitle("Transaction Drafts")
        .onAppear {
            drafts = TransactionDraftStore.load()
        }
        .sheet(item: $selectedDraft, onDismiss: { drafts = TransactionDraftStore.load() }) { draft in
            NavigationStack {
                ContinueDraftView(draftId: draft.id)
            }
        }
    }
}
