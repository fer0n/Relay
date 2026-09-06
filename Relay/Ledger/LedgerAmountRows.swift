//
//  LedgerAmountRows.swift
//  Relay
//
//  The two amount fields on the expense editor. Each owns its own
//  `@FocusState`, which is why they aren't inlined there.
//

import SwiftUI

/// `.decimalPad` has no return key, hence `dismissButtonToolbar`.
struct LedgerAmountFieldRow: View {
    let icon: String
    let title: LocalizedStringKey
    @Binding var text: String

    @FocusState private var isFocused: Bool

    var body: some View {
        DraftDetailRow(
            icon: icon,
            title: title,
            isIncomplete: SplitShareMath.cents(text) == nil
        ) {
            TextField("0", text: $text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .dismissButtonToolbar(isFocused: $isFocused)
        }
        .cardRowBackground()
    }
}

/// A `.manual` row. Its keyboard carries a "Remaining" button filling in
/// what's left of the total — the quick way to settle the last person.
struct LedgerManualAmountRow: View {
    let name: String
    @Binding var amount: String
    /// Nil when it can't be computed; negative disables the button.
    let remaining: Int?

    @FocusState private var isFocused: Bool

    var body: some View {
        DraftDetailRow(
            icon: Const.Symbol.person,
            title: "\(name)",
            isIncomplete: SplitShareMath.cents(amount) == nil
        ) {
            TextField("0", text: $amount)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .focused($isFocused)
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        if isFocused {
                            remainingToolbar
                        }
                    }
                }
        }
        .cardRowBackground()
    }

    @ViewBuilder
    private var remainingToolbar: some View {
        Button {
            if let remaining, remaining >= 0 {
                amount = SplitShareMath.text(fromCents: remaining)
            }
        } label: {
            if let remaining {
                Text("Remaining \(SplitShareMath.text(fromCents: remaining))")
            } else {
                Text("Remaining")
            }
        }
        .disabled((remaining ?? -1) < 0)

        Spacer()

        Button {
            isFocused = false
        } label: {
            Image(systemName: Const.Symbol.dismissKeyboard)
        }
        .buttonStyle(.plain)
    }
}
