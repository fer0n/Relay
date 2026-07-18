//
//  OnboardingWelcomePage.swift
//  Relay
//

import SwiftUI

struct OnboardingWelcomePage: View {
    let ynabAuth: YNABAuthService
    let splitwiseAuth: SplitwiseAuthService

    var body: some View {
        List {
            Section {
                AccountConnectionRow(
                    title: "YNAB",
                    isConnected: ynabAuth.isAuthenticated,
                    connect: ynabAuth.signIn,
                    disconnect: ynabAuth.signOut,
                    highlightWhenDisconnected: true
                )

                AccountConnectionRow(
                    title: "Splitwise",
                    isConnected: splitwiseAuth.isAuthenticated,
                    connect: splitwiseAuth.signIn,
                    disconnect: splitwiseAuth.signOut,
                    highlightWhenDisconnected: true
                )

                if splitwiseAuth.isAuthenticated {
                    DefaultSplitwiseFriendRow()
                }
            }
            .cardRowBackground()
        }
        .themedList(background: .sheetBackgroundColor)
    }
}

#Preview {
    OnboardingWelcomePage(ynabAuth: YNABAuthService(), splitwiseAuth: SplitwiseAuthService())
}
