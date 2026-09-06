//
//  DiscardSection.swift
//  Relay
//
//  A centered red button behind a destructive confirmationDialog. Used for
//  "Discard" by the continue flow and the pending detail view, and "Delete"
//  by the ledger expense editor — which reaches the network, hence the
//  async `onConfirm`.
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
