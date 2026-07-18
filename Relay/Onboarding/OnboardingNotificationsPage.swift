//
//  OnboardingNotificationsPage.swift
//  Relay
//

import SwiftUI

/// Purely illustrative — the bottom "Enable Notifications" button in
/// OnboardingView (not a button here) does the actual permission request,
/// since it doubles as this page's primary action.
struct OnboardingNotificationsPage: View {
    var body: some View {
        Image(systemName: "app.badge")
            .font(.system(size: 100))
            .foregroundStyle(.secondary)
            .padding(.top, 40)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

#Preview {
    OnboardingNotificationsPage()
}
