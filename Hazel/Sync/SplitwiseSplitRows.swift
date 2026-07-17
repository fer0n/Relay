//
//  SplitwiseSplitRows.swift
//  Hazel
//
//  Row-level building blocks shared by ContinueYNABWalletTransactionView's
//  and ContinueSplitwiseWalletTransactionView's "Split" sections. The two
//  sections differ in row order and in which rows are gated/visible (the
//  YNAB flow gates the whole section on Splitwise being connected and hides
//  the friend row when not splitting; the Splitwise flow always shows both
//  since it's Splitwise-primary), so each view still assembles its own
//  `Section("Split") { ... }` — only the individual rows are shared.
//

import SwiftUI

/// The per-template "how should this split" row — read-only once a
/// template's setting is resolved, otherwise a live picker.
struct SplitwiseOptionRow: View {
    var title: String
    let isResolved: Bool
    let resolvedOption: SplitwiseTemplateOption
    @Binding var newOption: SplitwiseTemplateOption

    var body: some View {
        DraftDetailRow(icon: "divide.circle.fill", title: title) {
            if isResolved {
                Text(resolvedOption.label)
            } else {
                Picker(selection: $newOption) {
                    ForEach([SplitwiseTemplateOption.ask, .always, .manual, .never], id: \.self) { option in
                        Text(option.label).tag(option)
                    }
                } label: {
                    EmptyView()
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .tint(Color.foregroundColor)
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

    var body: some View {
        DraftDetailRow(icon: "person.2.fill", title: "Split With") {
            if let resolvedFriendName {
                Text(resolvedFriendName)
            } else if isLoading {
                ProgressView()
            } else {
                Picker(selection: $selectedFriendId) {
                    Text("None").tag(Int?.none)
                    splitwiseFriendRows(friends) { friend in
                        Text(friend.fullName).tag(Optional(friend.id))
                    }
                } label: {
                    EmptyView()
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .tint(Color.foregroundColor)
            }
        }
        .cardRowBackground()
    }
}

/// The live "ask each time" prompt — only shown while a template's split
/// setting is `.ask` and no runtime choice has been made yet this run.
struct SplitwiseAskRow: View {
    @Binding var runtimeChoice: SplitwiseSplitOption?

    var body: some View {
        DraftDetailRow(icon: "questionmark.circle.fill", title: "Split Transaction?") {
            Picker(selection: $runtimeChoice) {
                Text("Choose").tag(SplitwiseSplitOption?.none)
                ForEach([SplitwiseSplitOption.always, .manual, .never], id: \.self) { option in
                    Text(option.label).tag(SplitwiseSplitOption?.some(option))
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .tint(Color.foregroundColor)
        }
        .cardRowBackground()
    }
}

/// The manual own-share amount entry — only shown for a `.manual` split.
struct SplitwiseOwnShareRow: View {
    @Binding var ownShareText: String

    var body: some View {
        DraftDetailRow(icon: "eurosign.circle.fill", title: "Your Share") {
            TextField("Your Share", text: $ownShareText)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
        }
        .cardRowBackground()
    }
}
