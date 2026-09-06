//
//  RelayApp.swift
//  Relay
//

import SwiftUI

@main
struct RelayApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        // Before anything reads the stores it clears — several of them would
        // otherwise fail to decode and reset themselves anyway.
        SplitwiseRemovalMigration.runIfNeeded()
        // Must happen before any notification response can arrive —
        // UNUserNotificationCenter only delivers a tap to a delegate that's
        // already set.
        DraftNotificationRouter.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .scrollEdgeEffectStyle(.soft, for: .all)
        }
    }
}
