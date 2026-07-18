//
//  OnboardingAutomationPage.swift
//  Relay
//

import SwiftUI

/// Purely illustrative — the bottom "Setup" button in OnboardingView (not a
/// button here) closes onboarding and opens the automation tutorial, since
/// it doubles as this page's primary action.
struct OnboardingAutomationPage: View {
    var body: some View {
        Image(systemName: "wand.and.stars")
            .font(.system(size: 100))
            .foregroundStyle(.secondary)
            .padding(.top, 40)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

#Preview {
    OnboardingAutomationPage()
}
