//
//  AppDelegate.swift
//  Relay
//
//  Exists solely to wire up a scene delegate that can catch the Home Screen
//  quick action (long-press the app icon → "New Transaction") — SwiftUI's
//  default WindowGroup has no hook for UIApplicationShortcutItem, so this is
//  the minimal UIKit shim needed to receive it and forward it into
//  DraftNotificationRouter, same deep-link shape as a tapped notification.
//

import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = QuickActionSceneDelegate.self
        return configuration
    }
}

final class QuickActionSceneDelegate: NSObject, UIWindowSceneDelegate {
    /// Must stay in sync with the `UIApplicationShortcutItemType` declared in
    /// Info.plist.
    static let newTransactionShortcutType = "\(Const.bundleID).newTransaction"

    /// Cold launch — the shortcut item arrives as connection options rather
    /// than a `performActionFor` call.
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let shortcutItem = connectionOptions.shortcutItem {
            handle(shortcutItem)
        }
    }

    /// Warm launch — app was already running/suspended.
    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem, completionHandler: @escaping (Bool) -> Void) {
        completionHandler(handle(shortcutItem))
    }

    @discardableResult
    private func handle(_ shortcutItem: UIApplicationShortcutItem) -> Bool {
        guard shortcutItem.type == Self.newTransactionShortcutType else { return false }
        Task { @MainActor in
            DraftNotificationRouter.shared.pendingQuickActionNewTransaction = true
        }
        return true
    }
}
