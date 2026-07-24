//
//  Theme.swift
//  Relay
//

import SwiftUI
import UIKit

extension Color {
    static let foregroundColor = Color("ForegroundColor")
    static let backgroundColor = Color("BackgroundColor")
    static let sheetBackgroundColor = Color("SheetBackgroundColor")
    static let sheetInsetColor = Color("SheetInsetColor")
}

struct UnreadBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.footnote)
            .fontWeight(.black)
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }
}

struct ListChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 13))
            .fontWeight(.black)
            .foregroundStyle(.secondary)
            .padding(.trailing, 5)
    }
}

/// Standard row label for a `NavigationLink` in a themed `List` — pairs
/// with `.navigationLinkIndicatorVisibility(.hidden)` on the enclosing
/// List, since `ListChevron` replaces the native disclosure indicator.
struct RowLabel: View {
    let title: LocalizedStringKey
    var systemImage: String?
    var badge: Int?

    var body: some View {
        HStack(spacing: 7) {
            if let systemImage {
                Image(systemName: systemImage)
                    .fontWeight(.bold)
                    .foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .center)
            }
            Text(title)
            Spacer()
            if let badge, badge > 0 {
                UnreadBadge(count: badge)
            }
            ListChevron()
        }
    }
}

/// A menu-style `Picker` whose collapsed button shows a caller-supplied
/// label instead of the system-derived one. A plain `Picker(...)
/// .pickerStyle(.menu).labelsHidden()` has a longstanding SwiftUI bug where
/// its auto-derived collapsed label ignores `.lineLimit` applied from
/// outside, so a longer option's text can wrap to two lines instead of
/// truncating (https://stackoverflow.com/q/75423473). Wrapping the Picker
/// in a `Menu` with an explicit label sidesteps that, since the label is
/// then just a `Text` we control directly.
struct MenuPickerField<Selection: Hashable, Content: View>: View {
    @Binding var selection: Selection
    let label: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        Menu {
            Picker(selection: $selection) {
                content()
            } label: {
                EmptyView()
            }
        } label: {
            Text(label)
                .lineLimit(1)
        }
        .tint(Color.foregroundColor)
    }
}

/// Faint, oversized icon watermark shown behind an empty themed `List` —
/// pairs with `.background { if isEmpty { EmptyListBackground(...) } }`
/// on the List, in place of a titled `ContentUnavailableView`.
struct EmptyListBackground: View {
    var systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 100, weight: .bold))
            .foregroundStyle(.secondary)
            .opacity(0.15)
            .padding(70)
            .ignoresSafeArea()
    }
}

/// Visually mimics a system `.alert()` — title/message over a button row —
/// while staying a plain view that lays out inline wherever it's placed,
/// rather than presenting as a floating modal. Styled after iOS 26's Liquid
/// Glass alerts: the buttons are their own inset glass pills rather than
/// full-bleed rows split by hairline dividers, with their corner radius kept
/// concentric with the card's (inner radius = outer radius − the inset).
struct InlineAlertCard: View {
    let title: String
    var message: String?
    let buttons: [(title: String, action: () -> Void)]

    private let cornerRadius: CGFloat = 32
    private let inset: CGFloat = 10

    var body: some View {
        GlassEffectContainer(spacing: inset) {
            VStack(spacing: inset) {
                VStack(spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .multilineTextAlignment(.leading)
                    if let message {
                        Text(message)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 15)

                HStack {
                    ForEach(Array(buttons.enumerated()), id: \.offset) { _, button in
                        Button {
                            button.action()
                        } label: {
                            Text(button.title)
                                .padding(7)
                                .frame(maxWidth: .infinity)
                        }
                        .tint(Color.foregroundColor)
                        .buttonStyle(.bordered)
                    }
                }
            }
            .padding(inset)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .frame(maxWidth: 270)
    }
}

/// Prominent Liquid Glass action button pinned to the bottom safe area
/// (Save / Import / Add Expense / Add Transaction). Shows a spinner in
/// place of the label while `isLoading`, and applies the shared padding,
/// themed text, and glass styling every bottom bar uses — so the four
/// `safeAreaBar(edge: .bottom)` call sites don't each re-spell it.
struct BottomBarActionButton: View {
    let title: LocalizedStringKey
    var isLoading = false
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if isLoading {
                    ProgressView()
                } else {
                    Text(title).themedText()
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        .glassProminentActionButton()
        .disabled(isDisabled)
        .padding(.bottom, 5)
    }
}

/// Backs `View.bottomBarActionButton` — owns the keyboard-visibility state
/// so every call site gets the same "hidden while typing" rule for free
/// instead of re-declaring its own `@State private var isKeyboardVisible`.
private struct BottomBarActionButtonModifier: ViewModifier {
    let isPresented: Bool
    let title: LocalizedStringKey
    var isLoading = false
    var isDisabled = false
    let action: () -> Void

    @State private var isKeyboardVisible = false

    func body(content: Content) -> some View {
        content
            .safeAreaBar(edge: .bottom) {
                if isPresented, !isKeyboardVisible {
                    BottomBarActionButton(title: title, isLoading: isLoading, isDisabled: isDisabled, action: action)
                }
            }
            .onKeyboardVisibilityChange($isKeyboardVisible)
    }
}

extension View {
    /// The card-style row background used throughout themed Lists.
    func cardRowBackground() -> some View {
        listRowBackground(Color.sheetInsetColor)
    }

    /// Text styling shared by themed List rows and the bottom-bar Settings
    /// button label.
    func themedText() -> some View {
        self
            .font(.system(size: 18))
            .fontWeight(.medium)
            .foregroundStyle(Color.foregroundColor)
    }

    /// Standard style for a prominent Liquid Glass action button pinned to
    /// the bottom safe area (Save / Add Expense / Add Transaction). Forces
    /// dark color scheme because `.glassProminent` derives its label
    /// contrast from the color scheme rather than from `.foregroundStyle` —
    /// this also flips any themed color assets used by the label (e.g.
    /// `.themedText()`'s `Color.foregroundColor`) to their light variant, so
    /// the label reads correctly against the accent-tinted glass regardless
    /// of the app's actual light/dark mode.
    func glassProminentActionButton() -> some View {
        self
            .buttonStyle(.glassProminent)
            .tint(Color.accentColor)
            .colorScheme(.dark)
    }

    /// Tracks system keyboard visibility into `isVisible` — shared by every
    /// view that hides/adjusts a `safeAreaBar` action button while the
    /// keyboard is up (`safeAreaBar` docks its content right above the
    /// keyboard, which otherwise reads as the button chasing the keyboard up
    /// the screen).
    func onKeyboardVisibilityChange(_ isVisible: Binding<Bool>) -> some View {
        self
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                isVisible.wrappedValue = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                isVisible.wrappedValue = false
            }
    }

    /// A single `BottomBarActionButton` pinned to the bottom safe area,
    /// entirely absent while the keyboard is up rather than riding above it —
    /// `safeAreaBar` would otherwise reposition it right above the keyboard
    /// the moment it can be shown, which reads as the button chasing the
    /// keyboard up the screen. Shared by every screen with a single bottom
    /// action (Save, Add Transaction, Add Expense) so they all appear/
    /// disappear the same plain way instead of each spelling out its own
    /// keyboard-visibility tracking, with each screen free to drift on
    /// whether/how it animates.
    func bottomBarActionButton(
        isPresented: Bool,
        title: LocalizedStringKey,
        isLoading: Bool = false,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        modifier(BottomBarActionButtonModifier(isPresented: isPresented, title: title, isLoading: isLoading, isDisabled: isDisabled, action: action))
    }

    /// Binds this field's focus to `isFocused` and adds a keyboard-toolbar
    /// dismiss button (chevron-down, top right) — for keyboard types like
    /// `.decimalPad`/`.numberPad` that have no built-in return/dismiss key.
    func dismissButtonToolbar(isFocused: FocusState<Bool>.Binding) -> some View {
        self
            .focused(isFocused)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    if isFocused.wrappedValue {
                        Spacer()
                        Button {
                            isFocused.wrappedValue = false
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
    }

    /// Text styling shared by themed List section footers.
    func footerText() -> some View {
        self
            .font(.footnote)
            .fontWeight(.regular)
            .foregroundStyle(.secondary)
    }

    /// Applies Spine's list styling (hidden system row background, themed
    /// text, dimmed separators, and hidden native disclosure indicators in
    /// favor of `ListChevron`) without touching the background — use this
    /// directly when the screen also needs an `EmptyListBackground`, since
    /// that has to sit behind the (transparent) list but in front of the
    /// screen background, which a plain `.background(color)` can't express.
    func themedListStyle() -> some View {
        self
            .scrollContentBackground(.hidden)
            .themedText()
            .listRowSeparatorTint(Color.secondary.opacity(0.15))
            .navigationLinkIndicatorVisibility(.hidden)
    }

    /// `themedListStyle()` plus a plain screen background — the common case
    /// for a List with no empty state to show through it.
    func themedList(background: Color) -> some View {
        self
            .themedListStyle()
            .background(background)
    }
}
