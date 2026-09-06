//
//  LedgerRenameAlert.swift
//  Relay
//
//  Renaming a ledger, raised from two places — the row's context menu on
//  LedgersView and the detail screen's toolbar — so the wording and the
//  seeding of the field live here rather than being written out twice.
//

import SwiftUI

extension View {
    /// Presents the rename alert while `ledger` is non-nil.
    func ledgerRenameAlert(_ ledger: Binding<Ledger?>) -> some View {
        modifier(LedgerRenameAlert(ledger: ledger))
    }
}

private struct LedgerRenameAlert: ViewModifier {
    @Binding var ledger: Ledger?
    @State private var name = ""

    func body(content: Content) -> some View {
        content
            // Seeded on the way in rather than at each call site, so the
            // field opens on the name that's currently showing.
            .onChange(of: ledger?.id) { _, _ in
                if let ledger { name = ledger.name }
            }
            .alert(
                "Rename Ledger",
                isPresented: Binding(
                    get: { ledger != nil },
                    set: { if !$0 { ledger = nil } }
                ),
                presenting: ledger
            ) { ledger in
                TextField("Name", text: $name)
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    let name = name
                    Task { await LedgerStore.shared.rename(ledger, to: name) }
                }
            } message: { _ in
                Text("Everyone on the ledger sees this name.")
            }
    }
}
