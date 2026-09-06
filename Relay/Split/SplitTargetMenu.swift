//
//  SplitTargetMenu.swift
//  Relay
//
//  The menu behind every "pick one ledger, or one person on it" row.
//
//  Plain Buttons, not a Picker: a Picker's Section content doesn't reliably
//  render as an inline header inside a Menu, and the per-ledger grouping is
//  the whole point of this list.
//

import SwiftUI

struct SplitTargetMenu<Label: View>: View {
    let ledgers: [Ledger]
    /// "None", or "Default (…)" where an app-wide default applies.
    let noneLabel: String
    let onSelect: (WalletTransactionConfig.CachedSplitTarget?) -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Menu {
            Button(noneLabel) { onSelect(nil) }
            ForEach(ledgers) { ledger in
                Section(ledger.name) {
                    // The whole ledger first, then the people on it.
                    Button(ledger.name) {
                        onSelect(WalletTransactionConfig.CachedSplitTarget(ledger: ledger))
                    }
                    ForEach(ledger.others) { participant in
                        Button(participant.displayName) {
                            onSelect(WalletTransactionConfig.CachedSplitTarget(
                                ledger: ledger,
                                participant: participant
                            ))
                        }
                    }
                }
            }
        } label: {
            MenuPickerLabel(label: label)
        }
        .tint(Color.foregroundColor)
    }
}
