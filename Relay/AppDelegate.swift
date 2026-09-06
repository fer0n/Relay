//
//  AppDelegate.swift
//  Relay
//
//  Exists to wire up a scene delegate for the two things SwiftUI's
//  WindowGroup has no hook for:
//
//    * the Home Screen quick action (long-press the app icon → "New
//      Transaction"), forwarded into DraftNotificationRouter with the same
//      deep-link shape as a tapped notification
//    * an accepted CloudKit share — tapping a ledger invite link launches the
//      app with the share's metadata, and only a scene delegate receives it
//

import CloudKit
import UIKit
import os

final class AppDelegate: NSObject, UIApplicationDelegate {
    private static let logger = Logger(subsystem: Const.loggerSubsystem, category: "Ledger")

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // No permission prompt: a CloudKit silent push needs the device token,
        // not notification authorization. What the user is later asked for is
        // permission to *display* the local notification this posts, which the
        // Ledgers screen requests when they turn the setting on.
        application.registerForRemoteNotifications()
        Task { await LedgerChangeNotifier.subscribeIfNeeded() }
        return true
    }

    /// A ledger changed somewhere. The push carries no useful wording of its
    /// own — see LedgerChangeNotifier — so this fetches and lets that decide
    /// what, if anything, is worth telling the user.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        guard CKNotification(fromRemoteNotificationDictionary: userInfo) != nil else { return .noData }
        return await LedgerChangeNotifier.handleRemoteNotification() ? .newData : .noData
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Not fatal, and not worth showing: ledgers still refresh when opened.
        Self.logger.notice("Remote notification registration failed: \(error.localizedDescription, privacy: .public)")
    }

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
    private static let logger = Logger(subsystem: Const.loggerSubsystem, category: "Ledger")

    /// Must stay in sync with the `UIApplicationShortcutItemType` declared in
    /// Info.plist.
    static let newTransactionShortcutType = "\(Const.bundleID).newTransaction"

    /// Cold launch — the shortcut item, and any share tapped while the app
    /// wasn't running, arrive as connection options rather than as their own
    /// callbacks.
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let shortcutItem = connectionOptions.shortcutItem {
            handle(shortcutItem)
        }
        if let metadata = connectionOptions.cloudKitShareMetadata {
            accept(metadata)
        }
    }

    /// Warm launch — the user tapped a ledger invite while the app was already
    /// running.
    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        accept(metadata)
    }

    /// Joining is the whole of "being invited to a ledger": there's no
    /// server-side membership for Relay to record, so accepting the share and
    /// re-reading the shared database is the entire flow.
    private func accept(_ metadata: CKShare.Metadata) {
        Task {
            do {
                _ = try await CKContainer(identifier: LedgerService.containerIdentifier).accept(metadata)
            } catch {
                // Nothing to show: the share sheet has already dismissed by
                // now, and the ledger simply won't appear. A re-tap of the
                // link retries.
                Self.logger.error("Accepting ledger share failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            await LedgerStore.shared.reloadAfterAcceptingShare()
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
