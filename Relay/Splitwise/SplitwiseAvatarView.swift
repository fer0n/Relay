//
//  SplitwiseAvatarView.swift
//  Relay
//
//  Friend avatar for SplitwiseBalanceCard — loads through RemoteImageCache
//  (memory + disk, so it doesn't re-download every time a card appears) and
//  falls back to the plain `Const.Symbol.person` placeholder while loading, on
//  failure, or when the friend has no picture at all.
//

import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct SplitwiseAvatarView: View {
    let url: URL?
    let diameter: CGFloat
    let iconFont: Font
    /// What stands in for a missing picture. A group's placeholder is the
    /// two-person symbol, so an avatar-less group doesn't read as a person.
    var fallbackSymbol: String = Const.Symbol.person

    @State private var image: Image?

    var body: some View {
        Group {
            if let image {
                image
                    .resizable()
                    .scaledToFill()
                    .frame(width: diameter, height: diameter)
                    .clipShape(Circle())
            } else {
                Image(systemName: fallbackSymbol)
                    .font(iconFont)
                    .foregroundStyle(.secondary)
                    .frame(width: diameter, height: diameter)
                    .background(Color.secondary.opacity(0.15), in: Circle())
            }
        }
        .task(id: url) {
            image = nil
            guard let url else { return }
            guard let data = try? await RemoteImageCache.shared.data(for: url) else { return }
            image = Self.platformImage(from: data)
        }
    }

    private static func platformImage(from data: Data) -> Image? {
        #if os(macOS)
        guard let nsImage = NSImage(data: data) else { return nil }
        return Image(nsImage: nsImage)
        #else
        guard let uiImage = UIImage(data: data) else { return nil }
        return Image(uiImage: uiImage)
        #endif
    }
}
