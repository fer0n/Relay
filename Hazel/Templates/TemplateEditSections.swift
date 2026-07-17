//
//  TemplateEditSections.swift
//  Hazel
//
//  Self-contained Form sections for TemplateEditView — each owns just its
//  own list editing (add/delete/reorder-by-menu), independent of the rest
//  of the template's fields.
//

import SwiftUI

struct LinkedMerchant: Identifiable {
    let merchant: String
    var payeeName: String
    var id: String { merchant }
}

struct AutoMatchRulesSection: View {
    @Binding var rules: [WalletTransactionConfig.AutoMatchRule]

    var body: some View {
        Section {
            if !rules.isEmpty {
                HStack {
                    Text("Payee Name")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Pattern")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            ForEach(rules.indices, id: \.self) { index in
                HStack {
                    TextField("Payee Name", text: $rules[index].payeeName)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Divider()
                    TextField("Text or regex", text: $rules[index].pattern)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .onDelete { rules.remove(atOffsets: $0) }
            Button("Add Rule") {
                rules.append(.init(pattern: "", payeeName: ""))
            }
        } header: {
            Text("Auto-Match Rules")
        } footer: {
            Text("Pattern can be plain text or a regex, and is matched case-insensitively.")
        }
    }
}

struct LinkedMerchantsSection: View {
    @Binding var linkedMerchants: [LinkedMerchant]
    let otherTemplateNames: [String]
    /// Repoints a merchant at a different, existing template — handled by
    /// the parent since it's independent of this screen's own pending
    /// edits/Save (the merchant no longer belongs to the template being
    /// edited here, so there's nothing left for Save to reconcile once it's
    /// removed from `linkedMerchants`).
    let onMove: (LinkedMerchant, String) -> Void

    var body: some View {
        Section {
            ForEach(linkedMerchants.indices, id: \.self) { index in
                let linked = linkedMerchants[index]
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(linked.merchant)
                        TextField("Payee Name", text: $linkedMerchants[index].payeeName)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !otherTemplateNames.isEmpty {
                        Menu {
                            ForEach(otherTemplateNames, id: \.self) { destination in
                                Button(destination) { onMove(linked, destination) }
                            }
                        } label: {
                            Image(systemName: "arrow.turn.up.right")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .onDelete { linkedMerchants.remove(atOffsets: $0) }
        } header: {
            Text("Linked Merchants")
        } footer: {
            Text("Wallet transactions from these exact merchant names go straight to this template. Edit the payee name, swipe to unlink one, or use the arrow to move one to a different template.")
        }
    }
}
