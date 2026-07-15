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

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(title)
                    .font(.headline)
                Text(isConnected ? "Connected" : "Not connected")
                    .font(.subheadline)
                    .foregroundStyle(isConnected ? .green : .secondary)
            }
            Spacer()
            Button(isConnected ? "Disconnect" : "Connect") {
                if isConnected {
                    disconnect()
                } else {
                    connect()
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(isConnected ? .red : .accentColor)
        }
    }
}
