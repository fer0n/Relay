//
//  PendingQueueView.swift
//  Hazel
//
//  Shows everything PendingOperationQueue is still waiting to send to YNAB
//  or Splitwise (queued because the device was offline when an intent ran),
//  with manual retry/delete since there's no OS-level background sync — see
//  PendingOperationQueue's header comment.
//

import SwiftUI

struct PendingQueueView: View {
    @State private var queue = PendingOperationQueue.shared
    @State private var isFlushing = false

    var body: some View {
        List {
            if queue.operations.isEmpty {
                ContentUnavailableView(
                    "All Synced",
                    systemImage: "checkmark.circle",
                    description: Text("Nothing is waiting to be sent to YNAB or Splitwise.")
                )
            } else {
                ForEach(queue.operations) { operation in
                    PendingOperationRow(operation: operation)
                        .swipeActions {
                            Button("Delete", role: .destructive) {
                                queue.delete(id: operation.id)
                            }
                            Button("Retry") {
                                Task { await queue.retryNow(id: operation.id) }
                            }
                            .tint(.blue)
                        }
                }
            }
        }
        .navigationTitle("Pending Queue")
        .toolbar {
            if !queue.operations.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task {
                            isFlushing = true
                            await queue.flush()
                            isFlushing = false
                        }
                    } label: {
                        if isFlushing {
                            ProgressView()
                        } else {
                            Text("Retry All")
                        }
                    }
                    .disabled(isFlushing)
                }
            }
        }
        .task {
            await queue.flush()
        }
    }
}

#Preview {
    NavigationStack {
        PendingQueueView()
    }
}
