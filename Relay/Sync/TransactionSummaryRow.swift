//
//  TransactionSummaryRow.swift
//  Relay
//
//  Shared summary row for a YNAB/Splitwise transaction — date on the left,
//  payee/description and service/category-or-friend in the middle, amount
//  on the right. Used for the pending queue, transaction drafts, and
//  recently created transactions.
//

import SwiftUI

struct TransactionSummaryRow: View {
    let service: TransactionService
    /// A second service shown alongside `service` for a combined
    /// YNAB+Splitwise entry (its icon and name follow the primary one).
    var secondaryService: TransactionService?
    let date: Date
    /// Payee (YNAB) or description (Splitwise).
    let title: String
    let amount: String
    /// Overrides the amount's color (e.g. green for a Splitwise expense the
    /// signed-in user lent money on) — nil keeps the default themed text
    /// color every other call site relies on.
    var amountColor: Color?
    /// Category name (YNAB) or friend's name (Splitwise) — nil hides the
    /// "· detail" suffix (e.g. a draft, where nothing's been chosen yet).
    var detail: String?
    var errorMessage: String?

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
                    if errorMessage != nil {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Image(systemName: service.systemImage)
                    if let secondaryService {
                        Image(systemName: secondaryService.systemImage)
                    }
                    if let detail {
                        Text("· \(detail)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            Group {
                if let amountColor {
                    Text(amount).foregroundStyle(amountColor)
                } else {
                    Text(amount)
                }
            }
            .font(.body)
            .monospacedDigit()
            .fontWeight(.semibold)
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    List {
        TransactionSummaryRow(service: .ynab, date: Date(), title: "Coffee Shop", amount: "-4.50", detail: "Dining Out")
        TransactionSummaryRow(service: .splitwise, date: Date().addingTimeInterval(-86400 * 3), title: "Groceries", amount: "32.10", detail: "Alex")
        TransactionSummaryRow(service: .ynab, secondaryService: .splitwise, date: Date().addingTimeInterval(-86400 * 7), title: "Restaurant", amount: "-45.00", detail: "Dining Out · Alex")
        TransactionSummaryRow(
            service: .ynab,
            date: Date().addingTimeInterval(-86400 * 20),
            title: "Starbucks",
            amount: "-12.34",
            errorMessage: "No connection — will retry automatically."
        )
    }
}
