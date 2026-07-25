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
    /// True when a template is required to submit (YNAB) rather than
    /// optional (Splitwise, which can auto-create one from the payee name).
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

/// The payee (YNAB) / description (Splitwise) field — a plain text field
/// plus a custom keyboard toolbar that replaces the system predictive bar
/// with suggestions of its own. Owns the field's focus state since the
/// toolbar content only makes sense scoped to this field being focused.
struct PayeeFieldRow: View {
    let title: LocalizedStringKey
    /// A plain `String` (not a `LocalizedStringKey`) so callers can pass a
    /// runtime value — the Splitwise Description field uses the effective
    /// payee name as its placeholder so leaving it blank files the expense
    /// under that name.
    let placeholder: String
    @Binding var text: String
    /// Existing auto-match payee names matching what's typed so far — see
    /// ContinueWalletTransactionModel.suggestedPayeeNames.
    let suggestedNames: [String]
    /// Whether to offer "Add to <linkToTemplateName>" for the current text
    /// — see ContinueWalletTransactionModel.showsLinkToTemplate.
    let showsLinkToTemplate: Bool
    /// The template that action would add to — see
    /// ContinueWalletTransactionModel.linkToTemplateName.
    let linkToTemplateName: String
    let onLinkToTemplate: () -> Void
    /// When true, a blank field isn't flagged incomplete — used by the
    /// Splitwise Payee/Description fields, which fall back to the merchant /
    /// effective-payee shown in their placeholder rather than requiring input.
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

    /// Replaces the system predictive/autocorrect bar with plain-text
    /// suggestions (divider-separated, like the system bar's own
    /// candidates). Always exactly 3 equally-spaced slots (like the system
    /// bar's own 3-candidate layout) filled left to right; a slot past the
    /// last match stays blank rather than shrinking the others, so the
    /// dividers land in the same place regardless of how many matches there
    /// are. "Add to <template>" always claims the leftmost slot when
    /// matches are scarce (2 or fewer) for the currently typed text, ahead
    /// of any real suggestions rather than filling whatever slot is left.
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

/// The optional YNAB category for the transaction — a loading spinner while
/// categories load, otherwise a live picker.
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
