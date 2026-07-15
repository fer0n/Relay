//
//  SplitwiseFriendPickerRows.swift
//  Hazel
//
//  Shared content for every Splitwise friend picker (Menu or Picker) so the
//  "Outstanding Balance" grouping only has one place to get out of sync —
//  used by DefaultSplitwiseFriendRow, TemplateEditView, and both
//  ContinueXWalletTransactionView friend pickers.
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
