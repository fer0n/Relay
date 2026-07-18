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
    case continueDraft(UUID)
}
