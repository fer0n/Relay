//
//  SplitwiseFriendPickerRows.swift
//  Hazel
//
//  Shared content for every Splitwise friend menu so the "Outstanding
//  Balance" grouping (and the Button-per-friend construction built on top
//  of it) only has one place each to get out of sync — used by
//  DefaultSplitwiseFriendRow, TemplateEditView, and both
//  ContinueXWalletTransactionView friend pickers (via SplitwiseFriendPickerRow).
//

import SwiftUI

@ViewBuilder
func splitwiseFriendRows<Row: View>(
    _ friends: [SplitwiseFriend],
    @ViewBuilder row: @escaping (SplitwiseFriend) -> Row
) -> some View {
    let (outstanding, settled) = friends.partitionedByBalance
    if outstanding.isEmpty {
        ForEach(friends, id: \.id, content: row)
    } else {
        Section("Outstanding Balance") {
            ForEach(outstanding, id: \.id, content: row)
        }
        ForEach(settled, id: \.id, content: row)
    }
}

/// The `Button`-per-friend content for a `Menu`-based friend picker —
/// shared by SplitwiseFriendPickerRow and DefaultSplitwiseFriendRow so
/// their menus stay in sync instead of each hand-rolling their own
/// `splitwiseFriendRows(friends) { friend in Button(...) }` call. Not a
/// Picker (see SplitwiseFriendPickerRow's comment) — plain Buttons, no
/// "currently selected" checkmark, since it looked out of place (visually
/// pushing just the selected row) rather than getting one for free.
@ViewBuilder
func splitwiseFriendMenuButtons(_ friends: [SplitwiseFriend], onSelect: @escaping (SplitwiseFriend) -> Void) -> some View {
    splitwiseFriendRows(friends) { friend in
        Button(friend.fullName) { onSelect(friend) }
    }
}
