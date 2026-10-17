//
//  AutomationTutorialView.swift
//  Relay
//
//  Hands the user a prebuilt Shortcuts automation via its iCloud share
//  link. Presented as its own sheet after OnboardingView's "Setup" button
//  dismisses onboarding, and reopenable from Settings.
//

import SwiftUI

struct AutomationTutorialView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private static let ynabAndSplitNotificationAutomationURL = URL(string: "https://www.icloud.com/shortcuts/b0effeabe59b44cfb9d3596c313bcbf8")!
    private static let ynabAndSplitWalletAutomationURL = URL(string: "https://www.icloud.com/shortcuts/3e03e82de7114012b08972f9e07b6175")!

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 100))
                .foregroundStyle(.secondary)
                .frame(maxHeight: .infinity)

            Text("Add an Automation")
                .font(.title2)
                .fontWeight(.bold)

            Text("Next time you pay, Relay will run automatically and add the transaction or prompt you with any necessary actions.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 6) {
                Label("Adjust the Notification Automation", systemImage: "slider.horizontal.3")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text("It's the most reliable option, but it has to match the notifications you get. After adding it in Shortcuts, set it to run for your bank's app or Wallet, then edit its regular expressions so they pick the merchant and amount out of that notification's title and body.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            VStack(spacing: 8) {
                Button {
                    open(Self.ynabAndSplitNotificationAutomationURL)
                } label: {
                    Text("Get Notification Automation")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)

                Button {
                    open(Self.ynabAndSplitWalletAutomationURL)
                } label: {
                    Text("Get Wallet Automation")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 30)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.sheetBackgroundColor)
    }

    private func open(_ url: URL) {
        openURL(url)
        dismiss()
    }
}

#Preview {
    AutomationTutorialView()
}
