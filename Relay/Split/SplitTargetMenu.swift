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
                    Button(ledger.name) { onSelect(Self.target(for: ledger)) }
                    ForEach(ledger.others) { participant in
                        Button(participant.displayName) {
                            onSelect(Self.target(for: ledger, participant: participant))
                        }
                    }
                }
            }
        } label: {
            MenuPickerLabel(label: label)
        }
        .tint(Color.foregroundColor)
    }

    private static func target(for ledger: Ledger) -> WalletTransactionConfig.CachedSplitTarget {
        WalletTransactionConfig.CachedSplitTarget(
            zoneName: ledger.zoneName,
            participantID: nil,
            firstName: ledger.name,
            fullName: ledger.name
        )
    }

    private static func target(
        for ledger: Ledger,
        participant: LedgerParticipant
    ) -> WalletTransactionConfig.CachedSplitTarget {
        WalletTransactionConfig.CachedSplitTarget(
            zoneName: ledger.zoneName,
            participantID: participant.id,
            firstName: participant.firstName,
            fullName: participant.displayName
        )
    }
}
