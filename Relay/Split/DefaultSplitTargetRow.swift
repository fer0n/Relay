//
//  DefaultSplitTargetRow.swift
//  Relay
//
//  Shown even with no ledgers: hiding it leaves no explanation of why
//  splitting isn't offered anywhere.
//

import SwiftUI

struct DefaultSplitTargetRow: View {
    @State private var store = LedgerStore.shared
    @State private var target = DefaultSplitTargetStore.load()

    private var ledgers: [Ledger] { store.sharedLedgers }

    var body: some View {
        DraftDetailRow(icon: Const.Symbol.friends, title: "Default Split") {
            if ledgers.isEmpty {
                Text("No shared ledgers")
                    .foregroundStyle(.secondary)
            } else {
                SplitTargetMenu(ledgers: ledgers, noneLabel: String(localized: "None"), onSelect: select) {
                    // The stored name, so an unloaded ledger still reads as set.
                    Text(target?.fullName ?? String(localized: "None"))
                }
            }
        }
        .task { await store.refresh(force: false) }
    }

    private func select(_ newTarget: WalletTransactionConfig.CachedSplitTarget?) {
        target = newTarget
        guard let newTarget else {
            DefaultSplitTargetStore.clear()
            return
        }
        try? DefaultSplitTargetStore.save(newTarget)
    }
}
