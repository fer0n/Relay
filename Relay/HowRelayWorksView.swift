//
//  HowRelayWorksView.swift
//  Relay
//
//  Plain-language transparency screen. Every claim must stay accurate to
//  YNABAuthService.swift, Relay/Ledger/ and oauth-relay/README.md.
//

import SwiftUI

struct HowRelayWorksView: View {
    var body: some View {
        List {
            Section {
                Text("Relay connects to YNAB using its official API to add transactions on your behalf, and imports bank statement files. Shared expenses live in your own iCloud — no other service is involved.")
            }
            .cardRowBackground()

            InfoSection(
                icon: "lock.fill",
                title: "Secure Login",
                text: "When you connect YNAB, Relay opens its own sign-in page in a secure browser window. Your username and password go directly to YNAB — Relay never sees or stores your credentials. Shared ledgers need no sign-in at all; they use the iCloud account already on your device."
            )

            InfoSection(
                icon: "key.fill",
                title: "Access Tokens",
                text: "Once you sign in, YNAB gives Relay a secure access token, stored safely on your device. Relay renews it automatically in the background, so you won't need to sign in again every couple of hours."
            )

            InfoSection(
                icon: "arrow.triangle.2.circlepath",
                title: "Sign-In Relay",
                text: "Part of the sign-in process briefly passes through a small relay service run by Relay's developer. It's only ever involved for a moment while you're signing in, and never sees your plan, transactions, or expenses."
            )

            InfoSection(
                icon: "checkmark.shield.fill",
                title: "Your Data",
                text: "Relay creates the transactions you ask for in YNAB, and keeps shared expenses in your own iCloud. Any bank or CSV statement files you import are read only on your device. Relay keeps no database of its own and never shares your financial data with anyone else."
            )
        }
        .themedList(background: .backgroundColor)
        .navigationTitle("How Relay Works")
    }
}

private struct InfoSection: View {
    let icon: String
    let title: LocalizedStringKey
    let text: LocalizedStringKey

    var body: some View {
        Section {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(Color.accentColor)
            Text(text)
                .foregroundStyle(.secondary)
        }
        .cardRowBackground()
    }
}

#Preview {
    NavigationStack {
        HowRelayWorksView()
    }
}
