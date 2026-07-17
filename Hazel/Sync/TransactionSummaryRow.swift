//
//  TransactionSummaryRow.swift
//  Hazel
//
//  Shared summary row for a YNAB/Splitwise transaction — date on the left,
//  payee/description and service/category-or-friend in the middle, amount
//  on the right. Used for the pending queue, transaction drafts, and
//  recently created transactions.
//

import SwiftUI

struct TransactionSummaryRow: View {
    let service: TransactionService
    let date: Date
    /// Payee (YNAB) or description (Splitwise).
    let title: String
    let amount: String
    /// Category name (YNAB) or friend's name (Splitwise) — nil hides the
    /// "· detail" suffix (e.g. a draft, where nothing's been chosen yet).
    var detail: String?
    var errorMessage: String?
    /// Set for rows that label a NavigationLink in a themed List, which
    /// hides the native disclosure indicator in favor of ListChevron.
    var showChevron = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(spacing: 0) {
                Text(date, format: .dateTime.month(.abbreviated))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(date, format: .dateTime.day())
                    .font(.title3.weight(.semibold))
            }
            .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body)
                    .fontWeight(.semibold)
                HStack(spacing: 4) {
                    Image(systemName: service.systemImage)
                    Text(service.displayName)
                    if let detail {
                        Text("· \(detail)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Text(amount)
                .font(.body)
                .monospacedDigit()
                .fontWeight(.semibold)

            if (showChevron) {
                ListChevron()
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    List {
        TransactionSummaryRow(service: .ynab, date: Date(), title: "Coffee Shop", amount: "-4.50", detail: "Dining Out", showChevron: true)
        TransactionSummaryRow(service: .splitwise, date: Date().addingTimeInterval(-86400 * 3), title: "Groceries", amount: "32.10", detail: "Alex")
        TransactionSummaryRow(
            service: .ynab,
            date: Date().addingTimeInterval(-86400 * 20),
            title: "Starbucks",
            amount: "-12.34",
            errorMessage: "No connection — will retry automatically."
        )
    }
}
