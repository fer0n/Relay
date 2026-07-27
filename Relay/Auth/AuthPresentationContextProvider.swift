//
//  AuthPresentationContextProvider.swift
//  Relay
//

import AuthenticationServices

#if os(macOS)
import AppKit
#else
import UIKit
#endif

final class AuthPresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    /// The `@available` is not a claim that callers should stop using this —
    /// nothing in the app calls it, the system does. It's the only way to
    /// confine the deprecated last-resort `ASPresentationAnchor()` below:
    /// iOS 26 deprecated every windowless `UIWindow` initializer in favour of
    /// `init(windowScene:)`, and a return value is still required for the
    /// no-scene case that has no scene to build one from. A deprecated context
    /// may use deprecated API, which keeps the branch without a warning and
    /// without pretending the unreachable case can't happen.
    @available(iOS, deprecated: 26.0, message: "Falls back to a windowless anchor when no window scene is connected.")
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(macOS)
        return NSApplication.shared.windows.first ?? ASPresentationAnchor()
        #else
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap(\.windows)
        if let keyWindow = windows.first(where: \.isKeyWindow) {
            return keyWindow
        }
        // No key window yet, but any window already in the hierarchy can still
        // present. Preferred over building one below: a freshly constructed
        // window is detached and has no root view controller, so presentation
        // from it fails just like the last-resort anchor does.
        if let window = windows.first {
            return window
        }
        // A scene with no windows at all — a window built on it is the best
        // anchor available.
        if let scene = scenes.first {
            return ASPresentationAnchor(windowScene: scene)
        }
        // Unreachable in practice: sign-in only starts from a visible screen,
        // which means at least one connected scene. Presentation would fail
        // here anyway, which `signInError` already surfaces — better than
        // trapping.
        return ASPresentationAnchor()
        #endif
    }
}
