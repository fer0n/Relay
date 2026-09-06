//
//  WalletTransactionRows.swift
//  Relay
//
//  ContinueWalletTransactionView's YNAB-side fields. The "Split" rows live
//  in Relay/Split/SplitRows.swift.
//

import SwiftUI

/// The width a keyboard toolbar's content should lay itself out at, published by
/// `keyboardBarWidthSource()`. Nil until the source view has been measured.
private struct KeyboardBarWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    var keyboardBarWidth: CGFloat? {
        get { self[KeyboardBarWidthKey.self] }
        set { self[KeyboardBarWidthKey.self] = newValue }
    }
}

extension View {
    /// Publishes this view's width, less the keyboard toolbar's own margins, for
    /// keyboard toolbars below it — apply it to a view that spans the screen.
    ///
    /// A keyboard toolbar sizes itself to its content rather than to the
    /// keyboard, so `maxWidth: .infinity` inside one is proposed nothing and
    /// collapses to the width of the content, leaving a bar floating in the
    /// middle of the keyboard. The width has to come from somewhere wider, and a
    /// row inside a card only knows the card's width.
    func keyboardBarWidthSource() -> some View {
        modifier(KeyboardBarWidthSource())
    }
}

private struct KeyboardBarWidthSource: ViewModifier {
    /// Inset of the keyboard toolbar's own container from the screen edges, one
    /// side. Measured off a screenshot — UIKit doesn't publish it.
    private static let containerInset: CGFloat = 16

    @State private var width: CGFloat?

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .environment(\.keyboardBarWidth, width.map { $0 - 2 * Self.containerInset })
    }
}

/// The template chooser — "Create New" (handed back via `onCreateNew`) plus
/// one button per saved template, selecting into `choice`.
struct TemplatePickerRow: View {
    let templates: [String]
    @Binding var choice: String?
    let onCreateNew: () -> Void
    /// True for YNAB, which requires a template; a split can auto-create one.
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

/// The payee (YNAB) / description (split) field, with a custom keyboard
/// toolbar of suggestions above the keyboard. Owns the focus state, since the
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
    /// Don't flag a blank field incomplete — for the split fields, which fall
    /// back to what their placeholder shows rather than requiring input.
    var allowsEmpty: Bool = false

    @FocusState private var isFocused: Bool
    /// See `keyboardBarWidthSource()`.
    @Environment(\.keyboardBarWidth) private var keyboardBarWidth

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
                // Both fields this row backs hold a name — a payee, or what
                // the expense was for — so every word is capitalised, not just
                // the first. Stated rather than left to the default because
                // autocorrection is off here, and "edeka" has nothing to
                // correct it to.
                .textInputAutocapitalization(.words)
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

    /// Mirrors the system predictive bar's 3-candidate layout: always exactly 3
    /// equally-spaced slots filled left to right, with a slot past the last match
    /// left blank rather than shrinking the others, so the dividers land in the
    /// same place however many matches there are. "Add to <template>" claims the
    /// leftmost slot ahead of any real suggestions.
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
            .frame(width: keyboardBarWidth)
        }
    }
}

/// No suggestion bar: unlike the payee, a memo is one-off text rather than a name
/// that repeats and is worth autocompleting. Also appended to the split
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
