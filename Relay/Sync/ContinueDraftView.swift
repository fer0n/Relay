//
//  ContinueDraftView.swift
//  Relay
//
//  Entry point for a tapped draft notification (or a tap in
//  TransactionDraftsView): loads the draft by id and routes to the matching
//  continue flow, or explains there's nothing left to do if it's already
//  been resolved (completed elsewhere, or dismissed) since the notification
//  fired.
//

import SwiftUI

struct ContinueDraftView: View {
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

#Preview {
    let draft = TransactionDraft(
        id: UUID(),
        startedAt: Date().addingTimeInterval(-3600),
        payload: .ynabWallet(merchant: "Coffee Shop", amount: 4.50, card: "Visa")
    )
    Color.clear
        .onAppear { try? TransactionDraftStore.save([draft]) }
        .sheet(isPresented: .constant(true)) {
            NavigationStack {
                ContinueDraftView(draftId: draft.id)
            }
        }
}
