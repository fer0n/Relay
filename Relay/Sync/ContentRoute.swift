//
//  ContentRoute.swift
//  Relay
//
//  Navigation destinations pushed onto ContentView's NavigationStack.
//  Needs to be an explicit, path-driven enum (rather than plain
//  NavigationLink { Destination() } pushes) so DraftNotificationRouter can
//  programmatically jump straight to a draft's continue flow from a tapped
//  notification, from anywhere in the stack.
//

import Foundation

enum ContentRoute: Hashable {
    case templates
    case pendingQueue
    case transactionDrafts
    case ledgers
    /// Carries the zone name rather than the `Ledger` itself: the route has to
    /// be `Hashable` and stable across a refresh, and the ledger's participant
    /// list changes under it as people accept a share.
    case ledger(zoneName: String)
    /// Same reasoning as `ledger` — and the screen this pushes is the one the
    /// participant list changes on, so it can't carry that list with it.
    case ledgerMembers(zoneName: String)
    case settings
    case howRelayWorks
}
