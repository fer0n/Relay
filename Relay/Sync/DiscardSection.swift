//
//  DiscardSection.swift
//  Relay
//
//  Shared destructive row — a centered, red-styled button gated behind
//  a destructive confirmationDialog. Used by the editable continue flow
//  (ContinueWalletTransactionView, "Discard"), the read-only pending detail
//  view (TransactionDetailView's PendingDetailContent, "Discard"), and the
//  read-only Splitwise expense detail view (SplitwiseExpenseDetailContent,
//  "Delete" — the only one of the three that reaches an actual network
//  call, hence `onConfirm` being async).
//

import SwiftUI

struct DiscardSection: View {
    var label: LocalizedStringKey = "Discard"
    let confirmationTitle: LocalizedStringKey
    /// Extra detail shown under the title — e.g. clarifying what the
    /// destructive action does or doesn't affect. Omitted when nil.
    var confirmationMessage: LocalizedStringKey? = nil
    let onConfirm: () async -> Void

    @State private var showConfirmation = false

    var body: some View {
        Section {
            Button(label) {
                showConfirmation = true
            }
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity)
            .confirmationDialog(
                confirmationTitle,
                isPresented: $showConfirmation,
                titleVisibility: .visible
            ) {
                Button("Confirm", role: .destructive) {
                    Task { await onConfirm() }
                }
            } message: {
                if let confirmationMessage {
                    Text(confirmationMessage)
                }
            }
        }
        .cardRowBackground()
    }
}
