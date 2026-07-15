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
            ForEach(queue.operations) { operation in
                PendingOperationRow(operation: operation)
                    .cardRowBackground()
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
        .themedListStyle()
        .background {
            Color.backgroundColor
            if queue.operations.isEmpty {
                EmptyListBackground(systemName: "checkmark.circle")
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
