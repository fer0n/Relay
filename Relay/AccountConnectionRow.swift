//
//  AccountConnectionRow.swift
//  Relay
//

import SwiftUI

struct AccountConnectionRow: View {
    let title: String
    let isConnected: Bool
    let connect: () -> Void
    let disconnect: () -> Void
    /// Draws attention to the Connect button with a filled, tinted style
    /// instead of the plain bordered one — used by the onboarding wizard to
    /// guide a new user toward connecting an account.
    var highlightWhenDisconnected: Bool = false

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
            connectButton
                .confirmationDialog(
                    "Disconnect from \(title)?",
                    isPresented: $showDisconnectConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Disconnect", role: .destructive, action: disconnect)
                }
        }
    }

    // `.bordered` and `.borderedProminent` are distinct concrete types, so
    // picking between them needs a branch rather than a ternary on
    // `.buttonStyle(...)`.
    @ViewBuilder
    private var connectButton: some View {
        let action = {
            if isConnected {
                showDisconnectConfirm = true
            } else {
                connect()
            }
        }
        Group {
            if highlightWhenDisconnected && !isConnected {
                Button(isConnected ? "Disconnect" : "Connect", action: action)
                    .buttonStyle(.borderedProminent)
            } else {
                Button(isConnected ? "Disconnect" : "Connect", action: action)
                    .buttonStyle(.bordered)
                    .tint(isConnected ? .gray : nil)
            }
        }
        // Buttons sit inside a themed List, which applies `.foregroundStyle`
        // to the whole hierarchy — that overrides the accent-tinted label
        // color these button styles would otherwise pick automatically, so
        // it must be forced back to a fixed light color here.
        .foregroundStyle(.white)
    }
}
