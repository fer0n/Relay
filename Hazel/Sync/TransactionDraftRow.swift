//
//  TransactionDraftRow.swift
//  Hazel
//

import SwiftUI

struct TransactionDraftRow: View {
    let draft: TransactionDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(
                    draft.service.displayName,
                    systemImage: draft.service == .ynab ? "banknote" : "person.2"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer()
                Text(draft.startedAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(draft.summary)
                .font(.body)
        }
        .padding(.vertical, 4)
    }
}
