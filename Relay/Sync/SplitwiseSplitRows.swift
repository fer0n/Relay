//
//  SplitwiseSplitRows.swift
//  Relay
//
//  Row-level building blocks shared by ContinueWalletTransactionView's
//  "Split" sections. The YNAB and Splitwise draft kinds differ in row order
//  and in which rows are gated/visible (the YNAB kind gates the whole
//  section on Splitwise being connected and hides the friend row when not
//  splitting; the Splitwise kind always shows both since it's
//  Splitwise-primary), so the view still assembles each kind's section
//  itself — only the individual rows are shared.
//

import SwiftUI

/// The per-template "how should this split" row — read-only once a
/// template's setting is resolved, otherwise a live picker.
struct SplitwiseOptionRow: View {
    var title: LocalizedStringKey
    let isResolved: Bool
    let resolvedOption: SplitwiseTemplateOption
    @Binding var newOption: SplitwiseTemplateOption

    var body: some View {
        DraftDetailRow(icon: "divide.circle.fill", title: title, isEditable: !isResolved) {
            if isResolved {
                Text(resolvedOption.label)
            } else {
                MenuPickerField(selection: $newOption, label: newOption.label) {
                    ForEach([SplitwiseTemplateOption.ask, .always, .manual, .never], id: \.self) { option in
                        Text(option.label).tag(option)
                    }
                }
            }
        }
        .cardRowBackground()
    }
}

/// Which Splitwise friend — or group — to split with, for the screens that
/// store exactly one target (a template, a staged file import). The
/// draft/manual forms use SplitwiseParticipantPickerRow instead, which can name
/// several people at once.
struct SplitwiseTargetPickerRow: View {
    let isLoading: Bool
    let friends: [SplitwiseFriend]
    let groups: [SplitwiseGroup]
    @Binding var target: WalletTransactionConfig.CachedSplitTarget?
    /// Label for the unset ("nothing selected") option — defaults to "None",
    /// but e.g. TemplateEditView passes "Default (…)" when an app-wide default
    /// applies instead.
    var noneLabel: String = "None"
    var isIncomplete: Bool = false

    var body: some View {
        DraftDetailRow(icon: Const.Symbol.friends, title: "Split With", isIncomplete: isIncomplete) {
            if isLoading, friends.isEmpty, groups.isEmpty {
                ProgressView()
            } else {
                // Not MenuPickerField here on purpose: a Picker's Section
                // content doesn't reliably show as an inline "Outstanding
                // Balance" header once the Picker itself is wrapped in a
                // Menu — SwiftUI tends to fold it into a submenu instead.
                // Plain Buttons in the Menu (splitwiseTargetMenuButtons,
                // shared with DefaultSplitwiseFriendRow) render Section
                // headers correctly.
                Menu {
                    Button(noneLabel) { target = nil }
                    splitwiseTargetMenuButtons(
                        friends: friends,
                        groups: groups,
                        onSelectFriend: { target = WalletTransactionConfig.CachedSplitTarget(id: $0.id, firstName: $0.firstName, fullName: $0.fullName) },
                        onSelectGroup: { target = WalletTransactionConfig.CachedSplitTarget(id: $0.id, firstName: $0.name, fullName: $0.name, isGroup: true) }
                    )
                } label: {
                    // The stored name, not a lookup: a group's members — or a
                    // friend dropped from a refreshed list — would otherwise
                    // show the row as unset while it isn't.
                    MenuPickerLabel { Text(target?.fullName ?? noneLabel) }
                }
                .tint(Color.foregroundColor)
            }
        }
        .cardRowBackground()
    }
}

/// A single unified "Split" picker for draft views — always shown, pre-filled
/// from the template's split setting. `nil` means the template uses "Ask Each
/// Time" and the user still needs to choose for this transaction.
struct SplitwiseSplitPickerRow: View {
    @Binding var choice: SplitwiseSplitChoice?
    var isIncomplete: Bool = false

    var body: some View {
        DraftDetailRow(
            icon: "divide.circle.fill",
            title: "Split",
            isIncomplete: isIncomplete
        ) {
            MenuPickerField(
                selection: $choice,
                label: choice?.label ?? "Choose"
            ) {
                Text("Choose").tag(SplitwiseSplitChoice?.none)
                ForEach([SplitwiseSplitChoice.always, .shares, .manual, .never], id: \.self) { option in
                    Text(option.label).tag(SplitwiseSplitChoice?.some(option))
                }
            }
        }
        .cardRowBackground()
    }
}

/// One participant's relative weight in a `.shares` split, with the amount it
/// works out to underneath. Its own view for the per-field `@FocusState`.
/// Shared by SplitwiseExpenseDetailView and the draft forms' "Split by Shares".
struct ShareWeightRow: View {
    let name: String
    /// Nil while the total is unparseable.
    let amountText: String?
    @Binding var weight: String

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: Const.Symbol.person)
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .padding(.trailing, 12)

            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .foregroundStyle(.secondary)
                if let amountText {
                    Text(amountText)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
            .lineLimit(1)

            Spacer(minLength: 10)

            TextField("0", text: $weight)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .foregroundStyle(SplitwiseShareMath.cents(weight) == nil ? Color.accentColor : Color.primary)
                .dismissButtonToolbar(isFocused: $isFocused)
        }
        .padding(.vertical, 3)
        .cardRowBackground()
    }
}

/// The manual own-share amount entry — only shown for a `.manual` split.
struct SplitwiseOwnShareRow: View {
    @Binding var ownShareText: String
    var isIncomplete: Bool = false

    @FocusState private var isFocused: Bool

    var body: some View {
        DraftDetailRow(
            icon: "eurosign.circle.fill",
            title: "Your Share",
            isIncomplete: isIncomplete
        ) {
            TextField("Your Share", text: $ownShareText)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .dismissButtonToolbar(isFocused: $isFocused)
        }
        .cardRowBackground()
    }
}
