//
//  TransactionDraftHeader.swift
//  Relay
//
//  Shared amount/merchant/started-time header for
//  ContinueYNABWalletTransactionView and ContinueSplitwiseWalletTransactionView.
//

import SwiftUI

struct TransactionDraftHeader: View {
    let amount: String
    let merchant: String
    let startedAt: Date

    var body: some View {
        VStack(spacing: 4) {
            Text(amount)
                .font(.system(size: 45, weight: .heavy))
                .foregroundStyle(Color.foregroundColor)
                .minimumScaleFactor(0.5)
            Text(merchant)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Started \(RelativeDateTimeFormatter().localizedString(for: startedAt, relativeTo: Date()))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
}

#Preview {
    List {
        Section {
            TransactionDraftHeader(amount: "-32.10", merchant: "Grocery Store", startedAt: Date().addingTimeInterval(-3600))
        }
        .listRowSeparator(.hidden)
        .listRowBackground(Color.backgroundColor)
    }
    .themedList(background: .backgroundColor)
}
