//
//  AutomationTutorialView.swift
//  Relay
//
//  Walks the user through building the Shortcuts personal automation that
//  triggers on an Apple Wallet transaction and opens Relay to add it.
//  Presented as its own sheet after OnboardingView's "Setup" button
//  dismisses onboarding — kept separate so it can be reopened later (e.g.
//  from Settings) without re-running the whole onboarding flow.
//

import SwiftUI

struct AutomationTutorialView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var page: TutorialPage = .step1
    @State private var direction: PageDirection = .forward
    @Namespace private var imageNamespace

    private enum PageDirection {
        case forward
        case backward
    }

    private enum TutorialPage: Int, CaseIterable, Hashable, Sendable {
        case step1
        case step2
        case step3
        case step4
        case step5
        case step6
        case step7

        var imageName: String? {
            switch self {
            case .step1, .step2, .step3, .step4, .step5, .step6:
                return "AutomationTutorialStep\(rawValue + 1)"
            case .step7:
                return nil
            }
        }

        var title: LocalizedStringKey {
            switch self {
            case .step1: return "Create a Wallet Automation"
            case .step2: return "Set It to Run Immediately"
            case .step3: return "Create a New Shortcut"
            case .step4: return "Setup Shortcut Action"
            case .step5: return "Add Amount Parameter"
            case .step6: return "Add Remaining Parameters"
            case .step7: return "Everything's Ready"
            }
        }

        var description: LocalizedStringKey {
            switch self {
            case .step1:
                return "In the Shortcuts app, create a personal automation and choose the Wallet trigger. Return here to continue."
            case .step2:
                return "Set the automation to run immediately for the best experience."
            case .step3:
                return "Select all cards & categories on the next screen. Then, tap \"Create New Shortcut\"."
            case .step4:
                return "Search actions for \"Add Wallet Transaction to YNAB\" (YNAB, optionally split with Splitwise) or \"Add Wallet Transaction to Splitwise\" (Splitwise only). Tap \"Amount\", scroll right, then select \"Shortcut Input\"."
            case .step5:
                return "Tap on \"Shortcut Input\" on top, then select \"Amount\"."
            case .step6:
                return "Repeat for Merchant (and Card, YNAB action only). Confirm it looks right, then tap the checkmark to save."
            case .step7:
                return "Next time you pay with Apple Pay on your phone, Relay will run automatically and add the transaction or prompt you with any necessary actions."
            }
        }

        var nextTitle: LocalizedStringKey {
            switch self {
            case .step1: return "Create Automation"
            case .step7: return "Done"
            default: return "Next"
            }
        }

        var previous: TutorialPage? {
            TutorialPage(rawValue: rawValue - 1)
        }

        var next: TutorialPage? {
            TutorialPage(rawValue: rawValue + 1)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                tutorialVisual
                    .id(page)
                    .matchedGeometryEffect(id: "tutorialImage", in: imageNamespace)
                    .transition(.opacity)
            }
            .padding(24)
            .frame(maxHeight: .infinity)
            .clipped()
            .animation(.easeInOut(duration: 0.25), value: page)

            VStack(spacing: 16) {
                Text(page.title)
                    .font(.title2)
                    .fontWeight(.bold)
                    .id(page)
                    .transition(.asymmetric(
                        insertion: .move(edge: direction == .forward ? .trailing : .leading).combined(with: .opacity),
                        removal: .move(edge: direction == .forward ? .leading : .trailing).combined(with: .opacity)
                    ))

                Text(page.description)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .id(page)
                    .transition(.asymmetric(
                        insertion: .move(edge: direction == .forward ? .trailing : .leading).combined(with: .opacity),
                        removal: .move(edge: direction == .forward ? .leading : .trailing).combined(with: .opacity)
                    ))

                HStack(spacing: 6) {
                    ForEach(TutorialPage.allCases, id: \.self) { candidate in
                        Circle()
                            .fill(candidate == page ? Color.secondary : Color.secondary.opacity(0.3))
                            .frame(width: 8, height: 8)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: page)

                Button {
                    switch page {
                    case .step1:
                        // "create-automation" jumps straight to the "New
                        // Automation" screen — it's undocumented (Apple only
                        // documents run-shortcut/open-shortcut x-callback-urls),
                        // but Shortcuts is a system app that's always installed,
                        // so this always has somewhere to land even if a future
                        // iOS drops the shortcut.
                        openURL(URL(string: "shortcuts://create-automation")!)
                        advancePage()
                    case .step7:
                        dismiss()
                    default:
                        advancePage()
                    }
                } label: {
                    Text(page.nextTitle)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            }
            .padding(.horizontal, 30)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity)
            .animation(.easeInOut(duration: 0.2), value: page)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    let horizontal = value.translation.width
                    guard abs(horizontal) > abs(value.translation.height), abs(horizontal) > 44 else {
                        return
                    }
                    if horizontal < 0 {
                        advancePage()
                    } else {
                        retreatPage()
                    }
                }
        )
        .background(Color.sheetBackgroundColor)
    }

    @ViewBuilder
    private var tutorialVisual: some View {
        if let imageName = page.imageName {
            Image(imageName)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Image(systemName: "checkmark.circle.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(Color.accentColor)
                .frame(width: 120, height: 120)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func advancePage() {
        guard let next = page.next else { return }
        direction = .forward
        withAnimation { page = next }
    }

    private func retreatPage() {
        guard let previous = page.previous else { return }
        direction = .backward
        withAnimation { page = previous }
    }
}

#Preview {
    AutomationTutorialView()
}
