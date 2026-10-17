//
//  AutomationTutorialView.swift
//  Relay
//
//  Hands the user a prebuilt Shortcuts Wallet automation via its iCloud
//  share link. Presented as its own sheet after OnboardingView's "Setup"
//  button dismisses onboarding, and reopenable from Settings.
//

import SwiftUI

struct AutomationTutorialView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private static let ynabAndSplitWalletAutomationURL = URL(string: "https://www.icloud.com/shortcuts/3e03e82de7114012b08972f9e07b6175")!

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 100))
                .foregroundStyle(.secondary)
                .frame(maxHeight: .infinity)

            Text("Add the Wallet Automation")
                .font(.title2)
                .fontWeight(.bold)

            Text("Add the shared automation to Shortcuts. Next time you pay with Apple Pay on your phone, Relay will run automatically and add the transaction or prompt you with any necessary actions.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                openURL(Self.ynabAndSplitWalletAutomationURL)
                dismiss()
            } label: {
                Text("Get Automation")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
        .padding(.horizontal, 30)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.sheetBackgroundColor)
    }
}

#Preview {
    AutomationTutorialView()
}
