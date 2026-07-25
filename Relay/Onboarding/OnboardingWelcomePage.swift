//
//  OnboardingWelcomePage.swift
//  Relay
//

import SwiftUI

struct OnboardingWelcomePage: View {
    let ynabAuth: YNABAuthService
    let splitwiseAuth: SplitwiseAuthService
    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            Section {
                AccountConnectionRow(
                    title: "YNAB",
                    isConnected: ynabAuth.isAuthenticated,
                    connect: ynabAuth.signIn,
                    disconnect: ynabAuth.signOut,
                    highlightWhenDisconnected: true,
                    connectedLabel: "Connected"
                )

                AccountConnectionRow(
                    title: "Splitwise",
                    isConnected: splitwiseAuth.isAuthenticated,
                    connect: splitwiseAuth.signIn,
                    disconnect: splitwiseAuth.signOut,
                    highlightWhenDisconnected: true,
                    connectedLabel: "Connected"
                )

            }
            .cardRowBackground()
        }
        .themedList(background: .sheetBackgroundColor)
        .alert(
            "Couldn't Connect to YNAB",
            isPresented: Binding(
                get: { ynabAuth.signInError != nil },
                set: { if !$0 { ynabAuth.clearSignInError() } }
            )
        ) {
            Button("Report Error") {
                openURL(SignInErrorMail.reportURL(
                    service: "YNAB",
                    message: ynabAuth.signInError ?? "",
                    detail: ynabAuth.signInErrorDetail
                ))
            }
            Button("OK", role: .cancel) { }
        } message: {
            Text(ynabAuth.signInError ?? "")
        }
        .alert(
            "Couldn't Connect to Splitwise",
            isPresented: Binding(
                get: { splitwiseAuth.signInError != nil },
                set: { if !$0 { splitwiseAuth.clearSignInError() } }
            )
        ) {
            Button("Report Error") {
                openURL(SignInErrorMail.reportURL(
                    service: "Splitwise",
                    message: splitwiseAuth.signInError ?? "",
                    detail: splitwiseAuth.signInErrorDetail
                ))
            }
            Button("OK", role: .cancel) { }
        } message: {
            Text(splitwiseAuth.signInError ?? "")
        }
    }
}

#Preview {
    OnboardingWelcomePage(ynabAuth: YNABAuthService(), splitwiseAuth: SplitwiseAuthService())
}
