//
//  AccountConnectionRow.swift
//  Hazel
//

import SwiftUI

struct AccountConnectionRow: View {
    let title: String
    let isConnected: Bool
    let connect: () -> Void
    let disconnect: () -> Void

    @State private var showDisconnectConfirm = false

    var body: some View {
        HStack {
            Text(title)
            if isConnected {
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
            }
            Spacer()
            Button(isConnected ? "Disconnect" : "Connect") {
                if isConnected {
                    showDisconnectConfirm = true
                } else {
                    connect()
                }
            }
            .buttonStyle(.bordered)
            .tint(isConnected ? .gray : nil)
            .confirmationDialog(
                "Disconnect from \(title)?",
                isPresented: $showDisconnectConfirm,
                titleVisibility: .visible
            ) {
                Button("Disconnect", role: .destructive, action: disconnect)
            }
        }
    }
}
