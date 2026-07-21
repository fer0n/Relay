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
        DraftDetailRow(icon: "divide.circle.fill", title: title) {
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

/// Which Splitwise friend to split with — a plain label once a friend is
/// already resolved (e.g. from a matched template), otherwise a loading
/// spinner or a live picker.
struct SplitwiseFriendPickerRow: View {
    var resolvedFriendName: String?
    let isLoading: Bool
    let friends: [SplitwiseFriend]
    @Binding var selectedFriendId: Int?
    /// Label for the unset ("no friend selected") option — defaults to
    /// "None", but e.g. TemplateEditView passes "Default (…)" when an
    /// app-wide default Splitwise friend applies instead.
    var noneLabel: String = "None"
    var isIncomplete: Bool = false

    var body: some View {
        DraftDetailRow(
            icon: "person.2.fill",
            title: "Split With",
            isIncomplete: isIncomplete
        ) {
            if let resolvedFriendName {
                Text(resolvedFriendName)
            } else if isLoading {
                ProgressView()
            } else {
                // Not MenuPickerField here on purpose: a Picker's Section
                // content doesn't reliably show as an inline "Outstanding
                // Balance" header once the Picker itself is wrapped in a
                // Menu — SwiftUI tends to fold it into a submenu instead.
                // Plain Buttons in the Menu (splitwiseFriendMenuButtons,
                // shared with DefaultSplitwiseFriendRow) render Section
                // headers correctly.
                Menu {
                    Button(noneLabel) { selectedFriendId = nil }
                    splitwiseFriendMenuButtons(friends) { selectedFriendId = $0.id }
                } label: {
                    Text(friends.first { $0.id == selectedFriendId }?.fullName ?? noneLabel)
                        .lineLimit(1)
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
    @Binding var choice: SplitwiseSplitOption?
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
                Text("Choose").tag(SplitwiseSplitOption?.none)
                ForEach([SplitwiseSplitOption.always, .manual, .never], id: \.self) { option in
                    Text(option.label).tag(SplitwiseSplitOption?.some(option))
                }
            }
        }
        .cardRowBackground()
    }
}

/// The manual own-share amount entry — only shown for a `.manual` split.
struct SplitwiseOwnShareRow: View {
    @Binding var ownShareText: String
    var isIncomplete: Bool = false

    var body: some View {
        DraftDetailRow(
            icon: "eurosign.circle.fill",
            title: "Your Share",
            isIncomplete: isIncomplete
        ) {
            TextField("Your Share", text: $ownShareText)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
        }
        .cardRowBackground()
    }
}
