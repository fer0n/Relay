//
//  DraftDetailRow.swift
//  Relay
//
//  Shared row style for ContinueWalletTransactionView's detail/split
//  sections: icon + label on the left, value/control trailing on the right.
//

import SwiftUI

struct DraftDetailRow<Content: View>: View {
    let icon: String
    let title: LocalizedStringKey
    /// Highlights the value in the accent color — used to flag a
    /// field that still needs to be filled out before the draft can submit.
    var isIncomplete: Bool = false
    /// Whether this row's value can actually be changed by the user — true
    /// for rows with a TextField/picker/toggle, false for a plain read-only
    /// value (e.g. a frozen history entry's Category or Account). Colors the
    /// value primary when editable, secondary when not, so a form mixing
    /// both kinds makes it obvious at a glance which fields respond to a tap.
    var isEditable: Bool = true
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .padding(.trailing, 12)

            Text(title)
                .lineLimit(1)
                .foregroundStyle(.secondary)

            Spacer(minLength: 10)
            content()
                .lineLimit(1)
                .foregroundStyle(isIncomplete ? Color.accentColor : (isEditable ? Color.primary : Color.secondary))
        }
        .padding(.vertical, 3)
    }
}

#Preview {
    List {
        Section {
            DraftDetailRow(icon: Const.Symbol.titleField, title: "Description") {
                Text("Grocery Store")
            }
            .cardRowBackground()

            DraftDetailRow(icon: Const.Symbol.template, title: "Template") {
                Text("New")
            }
            .cardRowBackground()

            DraftDetailRow(icon: "person.2", title: "Provider") {
                Text("Splitwise")
            }
            .cardRowBackground()
        }
    }
    .themedList(background: .backgroundColor)
}
