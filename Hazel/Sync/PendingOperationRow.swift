//
//  PendingOperationRow.swift
//  Hazel
//

import SwiftUI

struct PendingOperationRow: View {
    let operation: PendingOperation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(
                    operation.service == .ynab ? "YNAB" : "Splitwise",
                    systemImage: operation.service == .ynab ? "banknote" : "person.2"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer()
                Text(operation.queuedAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(operation.summary)
                .font(.body)
            if let lastError = operation.lastError {
                Text(lastError)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }
}
