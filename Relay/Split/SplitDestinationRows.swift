//
//  SplitDestinationRows.swift
//  Relay
//
//  Which ledger a split books in, and who on it. Tap, not type: a ledger's
//  cast is a handful of people.
//

import SwiftUI

/// Only rendered when there's more than one ledger.
struct SplitDestinationRow: View {
    let selectedLedgerName: String?
    let ledgers: [Ledger]
    /// A callback, not a binding: switching ledger replaces who's picked, or
    /// the previous ledger's participants get billed.
    let onSelectLedger: (Ledger) -> Void

    var body: some View {
        DraftDetailRow(icon: Const.Symbol.ledger, title: "Ledger") {
            Menu {
                ForEach(ledgers) { ledger in
                    Button(ledger.name) {
                        withAnimation { onSelectLedger(ledger) }
                    }
                }
            } label: {
                MenuPickerLabel { Text(selectedLedgerName ?? String(localized: "Ledger")) }
            }
            .tint(Color.foregroundColor)
        }
        .cardRowBackground()
    }
}

/// Everyone on the chosen ledger; tapping toggles them.
struct LedgerParticipantPickerRow: View {
    let ledger: Ledger?
    @Binding var selectedIDs: [String]
    var isIncomplete: Bool = false

    private var participants: [LedgerParticipant] {
        LedgerParticipantUsageStore.sorted(ledger?.others ?? [])
    }

    var body: some View {
        DraftDetailRow(icon: Const.Symbol.friends, title: "Split With", isIncomplete: isIncomplete) {
            if participants.isEmpty {
                // Not an error: a private list just can't be split in.
                Text("Nobody on this ledger yet")
                    .foregroundStyle(.secondary)
            } else {
                ChipFlow(spacing: 6) {
                    ForEach(participants) { participant in
                        LedgerParticipantChip(
                            title: participant.firstName,
                            isSelected: selectedIDs.contains(participant.id)
                        ) {
                            withAnimation { toggle(participant.id) }
                        }
                    }
                }
            }
        }
        .cardRowBackground()
    }

    private func toggle(_ id: String) {
        if let index = selectedIDs.firstIndex(of: id) {
            selectedIDs.remove(at: index)
        } else {
            selectedIDs.append(id)
        }
    }
}

struct LedgerParticipantChip: View {
    let title: String
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                if isSelected {
                    Image(systemName: Const.Symbol.checkmark)
                        .font(.caption2)
                        .fontWeight(.bold)
                }
                Text(title)
                    .lineLimit(1)
            }
            .font(.subheadline)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(isSelected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12))
            )
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
    }
}
