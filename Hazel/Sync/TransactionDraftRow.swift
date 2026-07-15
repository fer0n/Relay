//
//  TransactionDraftRow.swift
//  Hazel
//

import SwiftUI

struct TransactionDraftRow: View {
    let draft: TransactionDraft

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label(
                        draft.service.displayName,
                        systemImage: draft.service == .ynab ? "banknote.fill" : "person.2.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Spacer()
                    Text(draft.startedAt, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Text(draft.summary)
                    .font(.body)
            }
            .padding(.vertical, 4)
            ListChevron()
        }
    }
}

#Preview {
    List {
        TransactionDraftRow(draft: TransactionDraft(
            id: UUID(),
            startedAt: Date(),
            payload: .ynabWallet(merchant: "Coffee Shop", amount: 4.50, card: "Visa")
        ))
        TransactionDraftRow(draft: TransactionDraft(
            id: UUID(),
            startedAt: Date().addingTimeInterval(-3600),
            payload: .splitwiseWallet(merchant: "Grocery Store", amount: 32.10)
        ))
        TransactionDraftRow(draft: TransactionDraft(
            id: UUID(),
            startedAt: Date().addingTimeInterval(-86400 * 2),
            payload: .ynabWallet(merchant: "A Really Long Restaurant Name That Might Truncate", amount: 128.99, card: "Amex")
        ))
        TransactionDraftRow(draft: TransactionDraft(
            id: UUID(),
            startedAt: Date().addingTimeInterval(-60),
            payload: .splitwiseWallet(merchant: "Rent", amount: 1250)
        ))
        TransactionDraftRow(draft: TransactionDraft(
            id: UUID(),
            startedAt: Date().addingTimeInterval(-30 * 86400),
            payload: .ynabWallet(merchant: "Parking Meter", amount: 0, card: "Debit")
        ))
    }
}
