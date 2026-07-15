//
//  Theme.swift
//  Hazel
//

import SwiftUI

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
    let title: String
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
