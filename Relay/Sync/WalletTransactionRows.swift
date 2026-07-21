//
//  WalletTransactionRows.swift
//  Relay
//
//  Row-level building blocks for ContinueWalletTransactionView's YNAB-side
//  fields — the template, account, and category pickers. The Splitwise
//  "Split" rows live in SplitwiseSplitRows.swift; these mirror that split so
//  the main view just assembles rows instead of spelling each one out
//  inline.
//

import SwiftUI

/// The template chooser — "Create New" (handed back via `onCreateNew`) plus
/// one button per saved template, selecting into `choice`.
struct TemplatePickerRow: View {
    let templates: [String]
    @Binding var choice: String?
    let onCreateNew: () -> Void

    var body: some View {
        DraftDetailRow(icon: "doc.on.doc", title: "Template") {
            Menu {
                Button("Create New", action: onCreateNew)
                if !templates.isEmpty { Divider() }
                ForEach(templates.sorted(), id: \.self) { name in
                    Button(name) { choice = name }
                }
            } label: {
                Text(choice ?? "Select")
                    .foregroundStyle(choice == nil ? Color.accentColor : Color.secondary)
                    .lineLimit(1)
            }
        }
        .cardRowBackground()
    }
}

/// The YNAB account for the transaction — a plain label once the card is
/// already mapped (`isResolved`), otherwise a loading spinner or a live
/// picker. Titled with the originating card name.
struct AccountPickerRow: View {
    let cardName: String
    let isResolved: Bool
    let isLoading: Bool
    let accounts: [YNABAccount]
    @Binding var selection: String?

    var body: some View {
        DraftDetailRow(
            icon: "creditcard.fill",
            title: "\(cardName)",
            isIncomplete: selection == nil
        ) {
            if isResolved {
                Text(accounts.first { $0.id == selection }?.name ?? "Unknown")
            } else if isLoading {
                ProgressView()
            } else {
                MenuPickerField(
                    selection: $selection,
                    label: accounts.first { $0.id == selection }?.name ?? "Select account"
                ) {
                    Text("None").tag(String?.none)
                    ForEach(accounts, id: \.id) { account in
                        Text(account.name).tag(Optional(account.id))
                    }
                }
            }
        }
        .cardRowBackground()
    }
}

/// The optional YNAB category for the transaction — a loading spinner while
/// categories load, otherwise a live picker.
struct CategoryPickerRow: View {
    let isLoading: Bool
    let categories: [YNABCategory]
    @Binding var selection: String?

    var body: some View {
        DraftDetailRow(icon: "tag.fill", title: "Category") {
            if isLoading {
                ProgressView()
            } else {
                MenuPickerField(
                    selection: $selection,
                    label: categories.first { $0.id == selection }?.name ?? "Optional"
                ) {
                    Text("None").tag(String?.none)
                    ForEach(categories, id: \.id) { category in
                        Text(category.name).tag(Optional(category.id))
                    }
                }
            }
        }
        .cardRowBackground()
    }
}
