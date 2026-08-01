//
//  WalletTransactionRows.swift
//  Relay
//
//  Row-level building blocks for ContinueWalletTransactionView's YNAB-side
//  fields. The Splitwise "Split" rows live in SplitwiseSplitRows.swift.
//

import SwiftUI

/// The template chooser — "Create New" (handed back via `onCreateNew`) plus
/// one button per saved template, selecting into `choice`.
struct TemplatePickerRow: View {
    let templates: [String]
    @Binding var choice: String?
    let onCreateNew: () -> Void
    /// True for YNAB, which requires a template; Splitwise can auto-create one.
    var isIncomplete: Bool = false

    var body: some View {
        DraftDetailRow(icon: Const.Symbol.template, title: "Template", isIncomplete: isIncomplete) {
            Menu {
                Button("Create New", action: onCreateNew)
                if !templates.isEmpty { Divider() }
                ForEach(templates.sorted(), id: \.self) { name in
                    Button(name) { choice = name }
                }
            } label: {
                MenuPickerLabel { Text(choice ?? "Select") }
                    .foregroundStyle(choice == nil ? Color.accentColor : Color.primary)
            }
        }
        .cardRowBackground()
    }
}

/// A plain label once the card is already mapped (`isResolved`), otherwise a
/// loading spinner or a live picker.
struct AccountPickerRow: View {
    let cardName: String
    let isResolved: Bool
    let isLoading: Bool
    let accounts: [YNABAccount]
    @Binding var selection: String?

    var body: some View {
        DraftDetailRow(
            icon: Const.Symbol.account,
            title: "\(cardName)",
            isIncomplete: selection == nil,
            isEditable: !isResolved
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

/// The payee (YNAB) / description (Splitwise) field, with a custom keyboard
/// toolbar in place of the system predictive bar. Owns the focus state, since the
/// toolbar only makes sense scoped to this field.
struct PayeeFieldRow: View {
    let title: LocalizedStringKey
    /// A plain `String`, not a `LocalizedStringKey`, so callers can pass a runtime
    /// value — the Description field uses the effective payee name.
    let placeholder: String
    @Binding var text: String
    /// See ContinueWalletTransactionModel.suggestedPayeeNames.
let suggestedNames: [String]
    /// See ContinueWalletTransactionModel.showsLinkToTemplate.
let showsLinkToTemplate: Bool
    /// See ContinueWalletTransactionModel.linkToTemplateName.
    let linkToTemplateName: String
    let onLinkToTemplate: () -> Void
    /// Don't flag a blank field incomplete — for the Splitwise fields, which fall
    /// back to what their placeholder shows rather than requiring input.
    var allowsEmpty: Bool = false

    @FocusState private var isFocused: Bool

    var body: some View {
        DraftDetailRow(
            icon: Const.Symbol.titleField,
            title: title,
            isIncomplete: !allowsEmpty && text.trimmingCharacters(in: .whitespaces).isEmpty
        ) {
            TextField(placeholder, text: $text)
                .multilineTextAlignment(.trailing)
                .submitLabel(.done)
                .autocorrectionDisabled()
                .keyboardType(.alphabet)
                .focused($isFocused)
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        if isFocused {
                            suggestionsBar
                        }
                    }
                }
        }
        .cardRowBackground()
    }

    /// Replaces the system predictive bar, matching its 3-candidate layout: always
    /// exactly 3 equally-spaced slots filled left to right, with a slot past the
    /// last match left blank rather than shrinking the others, so the dividers
    /// land in the same place however many matches there are. "Add to <template>"
    /// claims the leftmost slot ahead of any real suggestions.
    private static let suggestionSlotCount = 3

    @ViewBuilder
    private var suggestionsBar: some View {
        if !suggestedNames.isEmpty || showsLinkToTemplate {
            HStack(spacing: 0) {
                ForEach(0..<Self.suggestionSlotCount, id: \.self) { index in
                    if index > 0 {
                        Divider()
                    }
                    Group {
                        if showsLinkToTemplate, index == 0 {
                            Button(action: onLinkToTemplate) {
                                VStack(spacing: 1) {
                                    Text(text.trimmingCharacters(in: .whitespaces))
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.8)
                                    Text("Add to \(linkToTemplateName)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        } else {
                            let nameIndex = showsLinkToTemplate ? index - 1 : index
                            if nameIndex < suggestedNames.count {
                                Button(suggestedNames[nameIndex]) {
                                    text = suggestedNames[nameIndex]
                                }
                                .buttonStyle(.plain)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            } else {
                                Color.clear
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 20)
                }
            }
            .foregroundStyle(Color.foregroundColor)
            .padding(.horizontal, 12)
        }
    }
}

/// No suggestion bar: unlike the payee, a memo is one-off text rather than a name
/// that repeats and is worth autocompleting. Also appended to the Splitwise
/// description when the transaction is split, so both sides carry the same note.
struct MemoFieldRow: View {
    @Binding var text: String

    var body: some View {
        DraftDetailRow(icon: "note.text", title: "Memo") {
            TextField("Optional", text: $text)
                .multilineTextAlignment(.trailing)
                .submitLabel(.done)
        }
        .cardRowBackground()
    }
}

/// A loading spinner while categories load, otherwise a live picker.
struct CategoryPickerRow: View {
    let isLoading: Bool
    let categories: [YNABCategory]
    @Binding var selection: String?

    var body: some View {
        DraftDetailRow(icon: Const.Symbol.category, title: "Category", isIncomplete: selection == nil) {
            if isLoading {
                ProgressView()
            } else {
                MenuPickerField(
                    selection: $selection,
                    label: categories.first { $0.id == selection }?.name ?? "Select"
                ) {
                    ForEach(categories, id: \.id) { category in
                        Text(category.name).tag(Optional(category.id))
                    }
                }
            }
        }
        .cardRowBackground()
    }
}
