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

/// Pairs with `.navigationLinkIndicatorVisibility(.hidden)` on the enclosing
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
                    .foregroundStyle(Color.accentColor)
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

/// The collapsed label shared by every `Menu`-based picker: the caller's content
/// plus the trailing indicator a native `Picker` would show.
struct MenuPickerLabel<Label: View>: View {
    @ViewBuilder var label: () -> Label

    var body: some View {
        HStack(spacing: 4) {
            label()
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .imageScale(.small)
        }
    }
}

/// A menu-style `Picker` with a caller-supplied collapsed label. Works around a
/// longstanding SwiftUI bug where `.pickerStyle(.menu).labelsHidden()`'s
/// auto-derived label ignores an outside `.lineLimit`, wrapping a long option to
/// two lines instead of truncating (https://stackoverflow.com/q/75423473).
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
            MenuPickerLabel { Text(label) }
        }
        .tint(Color.foregroundColor)
    }
}

/// Faint, oversized icon watermark behind an empty `List`, in place of a titled
/// `ContentUnavailableView`.
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

/// Mimics a system `.alert()` while staying a plain view that lays out inline
/// rather than presenting as a floating modal. Styled after iOS 26's Liquid Glass
/// alerts, with the buttons' corner radius kept concentric with the card's
/// (inner = outer − the inset).
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

/// Prominent Liquid Glass action button pinned to the bottom safe area, so the
/// `safeAreaBar(edge: .bottom)` call sites don't each re-spell its styling.
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

/// Backs `View.bottomBarActionButton`, owning the keyboard-visibility state so
/// every call site gets the same "hidden while typing" rule.
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

    func themedText() -> some View {
        self
            .font(.system(size: 18))
            .fontWeight(.medium)
            .foregroundStyle(Color.foregroundColor)
    }

    /// Forces dark color scheme because `.glassProminent` derives its label
    /// contrast from the color scheme rather than from `.foregroundStyle`. That
    /// also flips the label's themed color assets to their light variant, so it
    /// reads correctly against the accent-tinted glass in either mode.
    func glassProminentActionButton() -> some View {
        self
            .buttonStyle(.glassProminent)
            .tint(Color.accentColor)
            .colorScheme(.dark)
    }

    /// `safeAreaBar` docks its content right above the keyboard, which reads as
    /// the button chasing the keyboard up the screen — so its users hide it while
    /// the keyboard is up.
    func onKeyboardVisibilityChange(_ isVisible: Binding<Bool>) -> some View {
        self
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                isVisible.wrappedValue = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                isVisible.wrappedValue = false
            }
    }

    /// A single `BottomBarActionButton` pinned to the bottom safe area, absent
    /// while the keyboard is up rather than riding above it — see
    /// `KeyboardVisibilityModifier`.
    func bottomBarActionButton(
        isPresented: Bool,
        title: LocalizedStringKey,
        isLoading: Bool = false,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        modifier(BottomBarActionButtonModifier(isPresented: isPresented, title: title, isLoading: isLoading, isDisabled: isDisabled, action: action))
    }

    /// Adds a keyboard-toolbar dismiss button, for keyboard types like
    /// `.decimalPad` that have no return key of their own.
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
                            Image(systemName: Const.Symbol.dismissKeyboard)
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

    /// List styling without touching the background — use this directly when the
    /// screen also needs an `EmptyListBackground`, which has to sit behind the
    /// transparent list but in front of the screen background.
    func themedListStyle() -> some View {
        self
            .scrollContentBackground(.hidden)
            .themedText()
            .listRowSeparatorTint(Color.secondary.opacity(0.15))
            .navigationLinkIndicatorVisibility(.hidden)
    }

    /// The common case: a List with no empty state to show through it.
    func themedList(background: Color) -> some View {
        self
            .themedListStyle()
            .background(background)
    }
}
