//
//  RelayApp.swift
//  Relay
//

import SwiftUI

@main
struct RelayApp: App {
    init() {
        // Must happen before any notification response can arrive —
        // UNUserNotificationCenter only delivers a tap to a delegate that's
        // already set.
        DraftNotificationRouter.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
