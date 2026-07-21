//
//  HowRelayWorksView.swift
//  Relay
//
//  A user-facing transparency screen explaining how Relay's YNAB/Splitwise
//  connection actually works, in plain language. Every claim here must stay
//  accurate to the real implementation — see YNABAuthService.swift,
//  SplitwiseAuthService.swift, and oauth-relay/README.md. In particular:
//  Splitwise doesn't get the same background-refresh treatment YNAB does
//  (see SplitwiseAuthService.swift), so this deliberately doesn't claim it
//  does.
//

import SwiftUI

struct HowRelayWorksView: View {
    var body: some View {
        List {
            Section {
                Text("Relay connects to YNAB and Splitwise using their official APIs to add transactions and expenses on your behalf, and to import bank statement files into YNAB.")
            }
            .cardRowBackground()

            InfoSection(
                icon: "lock.fill",
                title: "Secure Login",
                text: "When you connect an account, Relay opens YNAB's or Splitwise's own sign-in page in a secure browser window. Your username and password go directly to them — Relay never sees or stores your credentials."
            )

            InfoSection(
                icon: "key.fill",
                title: "Access Tokens",
                text: "Once you sign in, YNAB or Splitwise gives Relay a secure access token, stored safely on your device. For YNAB, Relay renews this token automatically in the background, so you won't need to sign in again every couple of hours."
            )

            InfoSection(
                icon: "arrow.triangle.2.circlepath",
                title: "Sign-In Relay",
                text: "Part of the sign-in process briefly passes through a small relay service run by Relay's developer. It's only ever involved for a moment while you're signing in, and never sees your plan, transactions, or expenses."
            )

            InfoSection(
                icon: "checkmark.shield.fill",
                title: "Your Data",
                text: "Relay creates the transactions and expenses you ask for in YNAB and Splitwise. Any bank or CSV statement files you import are read only on your device. Relay keeps no database of its own and never shares your financial data with anyone else."
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
