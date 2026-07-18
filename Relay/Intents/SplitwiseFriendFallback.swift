//
//  SplitwiseFriendFallback.swift
//  Relay
//
//  Controls what AddWalletTransactionToYNABIntent does when its "Split
//  With" (splitwiseFriend) parameter is left unset: silently use the
//  app-configured default friend (ContentView's DefaultSplitwiseFriendRow /
//  SplitwiseDefaultFriendStore), or prompt live via requestDisambiguation.
//  Defaults to `.defaultFriend` so an out-of-the-box automation never
//  prompts unless the user opts into "Ask Each Time" in the editor.
//

import AppIntents

nonisolated enum SplitwiseFriendFallback: String, AppEnum, Codable {
    case defaultFriend
    case ask

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Splitwise Friend Fallback"
    static let caseDisplayRepresentations: [SplitwiseFriendFallback: DisplayRepresentation] = [
        .defaultFriend: "Use Default Friend",
        .ask: "Ask Each Time",
    ]
}
