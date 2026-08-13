//
//  SplitwiseFriendPickerRows.swift
//  Relay
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
        Section {
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

/// The same, plus the groups under a separator. Groups sit apart rather than
/// mixed in because they bill a whole membership, which is a different kind of
/// answer to "who do I split with" than one person — and a group with nobody in
/// it has no one to bill, so it isn't offered.
@ViewBuilder
func splitwiseTargetMenuButtons(
    friends: [SplitwiseFriend],
    groups: [SplitwiseGroup],
    onSelectFriend: @escaping (SplitwiseFriend) -> Void,
    onSelectGroup: @escaping (SplitwiseGroup) -> Void
) -> some View {
    splitwiseFriendMenuButtons(friends, onSelect: onSelectFriend)
    let selectableGroups = groups.filter { !$0.memberList.isEmpty }
    if !selectableGroups.isEmpty {
        Divider()
        ForEach(selectableGroups, id: \.id) { group in
            Button(group.name) { onSelectGroup(group) }
        }
    }
}
