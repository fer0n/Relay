//
//  DraftDetailRow.swift
//  Relay
//
//  Shared row style for ContinueYNABWalletTransactionView and
//  ContinueSplitwiseWalletTransactionView's detail/split sections: icon +
//  label on the left, value/control trailing on the right.
//

import SwiftUI

struct DraftDetailRow<Content: View>: View {
    let icon: String
    let title: String
    /// Highlights the icon and value in the accent color — used to flag a
    /// field that still needs to be filled out before the draft can submit.
    var isIncomplete: Bool = false
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

            Spacer(minLength: 10)
            content()
                .lineLimit(1)
                .foregroundStyle(isIncomplete ? Color.accentColor : Color.secondary)
        }
        .padding(.vertical, 3)
    }
}

#Preview {
    List {
        Section {
            DraftDetailRow(icon: "text.alignleft", title: "Description") {
                Text("Grocery Store")
            }
            .cardRowBackground()

            DraftDetailRow(icon: "doc.on.doc", title: "Template") {
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
