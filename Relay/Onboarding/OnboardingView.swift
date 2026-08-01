//
//  OnboardingView.swift
//  Relay
//

import SwiftUI
import UserNotifications

/// First-launch wizard walking a new user through connecting accounts,
/// notifications, and importing templates. Interactive dismissal is disabled, so
/// it only closes via the last page's Done button — swiping it away wouldn't
/// leave a visible way back in.
///
/// The logo, title, and description sit outside the paging scroll view so only
/// the content underneath moves; the header crossfades via `.id(page)` instead.
///
/// Paging uses `ScrollView` + `.scrollTargetBehavior(.paging)` rather than
/// `TabView(.page)`, whose selection can be set programmatically but only swaps
/// content in place. Tapping Continue needs the same slide a swipe produces,
/// which requires a scroll-position-driven pager inside `withAnimation`.
struct OnboardingView: View {
    @State private var ynabAuth = YNABAuthService()
    @State private var splitwiseAuth = SplitwiseAuthService()
    @State private var scrollPosition: OnboardingPage? = .welcome
    @State private var isRequestingNotificationPermission = false
    @State private var splitwiseFriendCanContinue = SplitwiseDefaultFriendStore.load() != nil
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    /// Called instead of dismissing outright on the last page: ContentView flags
    /// its state here and presents the tutorial from this sheet's `onDismiss`,
    /// rather than stacking a second sheet on one still on screen.
    var onRequestAutomationTutorial: () -> Void = {}

    private var page: OnboardingPage { scrollPosition ?? .welcome }

    private var isContinueDisabled: Bool {
        switch page {
        case .welcome:
            return !ynabAuth.isAuthenticated && !splitwiseAuth.isAuthenticated
        case .splitwiseFriend:
            return !splitwiseFriendCanContinue
        case .notifications:
            return isRequestingNotificationPermission
                || (splitwiseAuth.isAuthenticated && !splitwiseFriendCanContinue)
        case .automation:
            return false
        }
    }

    private var isSecondaryDisabled: Bool {
        switch page {
        case .welcome:
            return false
        case .splitwiseFriend:
            return false
        case .notifications:
            return isRequestingNotificationPermission
        case .automation:
            return false
        }
    }

    private var continueTitle: LocalizedStringKey {
        switch page {
        case .welcome: return "Continue"
        case .splitwiseFriend: return "Continue"
        case .notifications: return "Enable Notifications"
        case .automation: return "Setup Automation"
        }
    }

    private var secondaryTitle: LocalizedStringKey {
        switch page {
        case .welcome: return "Skip"
        case .splitwiseFriend: return "Skip"
        case .notifications: return "Skip"
        case .automation: return "Close"
        }
    }

    private enum OnboardingPage: Int, CaseIterable, Hashable, Sendable {
        case welcome
        case splitwiseFriend
        case notifications
        case automation

        var title: LocalizedStringKey {
            switch self {
            case .welcome: return "Welcome to Relay"
            case .splitwiseFriend: return "Split with"
            case .notifications: return "Enable Reminders"
            case .automation: return "Setup Wallet Automation"
            }
        }

        var description: LocalizedStringKey {
            switch self {
            case .welcome:
                return "Connect YNAB and/or Splitwise to get started"
            case .splitwiseFriend:
                return "Choose who to split expenses with by default"
            case .notifications:
                return "Reminds you about an incomplete wallet transaction or offline transactions that are waiting to sync. Nothing else."
            case .automation:
                return "Add a Shortcuts automation that adds a transaction via Relay whenever you tap to pay with Apple Wallet."
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Image("OnboardingLogo")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 200, maxHeight: 180)
                .frame(maxWidth: .infinity)
                .padding(.top, 24)
                .opacity(0.8)

            ZStack {
                Text(page.title)
                    .font(.title)
                    .fontWeight(.bold)
                    .id(page)
                    .transition(.opacity)
                    .minimumScaleFactor(0.5)
            }
            .frame(height: 34)
            .animation(.easeInOut(duration: 0.2), value: page)
            .padding(.top, 12)

            // All three stay mounted, crossfading via opacity, rather than swapping
            // one Text via .id: the ZStack's height is then always the tallest of
            // them, so it needs no fixed height yet never jumps between pages.
            ZStack(alignment: .top) {
                ForEach(OnboardingPage.allCases, id: \.self) { candidate in
                    Text(candidate.description)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 25)
                        .opacity(candidate == page ? 1 : 0)
                        .accessibilityHidden(candidate != page)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: page)
            .padding(.top, 10)

            // Fills the space between the header and the dots below, so this
            // container's size never depends on which page is showing and swiping
            // between pages of different heights doesn't move them.
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    OnboardingWelcomePage(ynabAuth: ynabAuth, splitwiseAuth: splitwiseAuth)
                        .containerRelativeFrame(.horizontal)
                        .id(OnboardingPage.welcome)

                    OnboardingSplitwiseFriendPage(splitwiseAuth: splitwiseAuth, canContinue: $splitwiseFriendCanContinue)
                        .containerRelativeFrame(.horizontal)
                        .id(OnboardingPage.splitwiseFriend)

                    OnboardingNotificationsPage()
                        .containerRelativeFrame(.horizontal)
                        .id(OnboardingPage.notifications)

                    OnboardingAutomationPage()
                        .containerRelativeFrame(.horizontal)
                        .id(OnboardingPage.automation)
                }
                .scrollTargetLayout()
            }
            .frame(maxHeight: .infinity)
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $scrollPosition)
            .scrollIndicators(.hidden)

            HStack(spacing: 6) {
                ForEach(OnboardingPage.allCases.filter { $0 != .splitwiseFriend || splitwiseAuth.isAuthenticated }, id: \.self) { candidate in
                    Circle()
                        .fill(candidate == page ? Color.secondary : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.top, 8)
            .animation(.easeInOut(duration: 0.2), value: page)
            .padding(.bottom, 16)

            VStack(spacing: 10) {
                Button {
                    switch page {
                    case .welcome:
                        if splitwiseAuth.isAuthenticated {
                            withAnimation { scrollPosition = .splitwiseFriend }
                        } else {
                            withAnimation { scrollPosition = .notifications }
                        }
                    case .splitwiseFriend:
                        withAnimation { scrollPosition = .notifications }
                    case .notifications:
                        withAnimation { scrollPosition = .automation }
                    case .automation:
                        dismiss()
                    }
                } label: {
                    Text(secondaryTitle)
                        .frame(maxWidth: .infinity)
                }
                .disabled(isSecondaryDisabled)
                .padding(.horizontal, 30)
                .buttonStyle(.bordered)
                .tint(Color.foregroundColor)
                .controlSize(.large)
                .frame(maxWidth: .infinity)

                Button {
                    switch page {
                    case .welcome:
                        if splitwiseAuth.isAuthenticated {
                            withAnimation { scrollPosition = .splitwiseFriend }
                        } else {
                            withAnimation { scrollPosition = .notifications }
                        }
                    case .splitwiseFriend:
                        withAnimation { scrollPosition = .notifications }
                    case .notifications:
                        NotificationsPreferenceStore.isEnabled = true
                        isRequestingNotificationPermission = true
                        Task {
                            await requestNotificationPermission()
                            await MainActor.run {
                                isRequestingNotificationPermission = false
                                withAnimation { scrollPosition = .automation }
                            }
                        }
                    case .automation:
                        onRequestAutomationTutorial()
                        dismiss()
                    }
                } label: {
                    Text(continueTitle)
                        .frame(maxWidth: .infinity)
                }
                .disabled(isContinueDisabled)
                .padding(.horizontal, 30)
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            }
            .padding(.bottom, 10)
            .fontWeight(.semibold)
        }
        .background(Color.sheetBackgroundColor)
        .sensoryFeedback(.selection, trigger: page)
    }

    // Requesting more than once is a no-op once the user has already
    // answered the system prompt, matching SettingsView's toggle behavior.
    private func requestNotificationPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }
}

#Preview {
    OnboardingView()
}

