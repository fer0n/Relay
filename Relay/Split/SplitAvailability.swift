//
//  SplitAvailability.swift
//  Relay
//

import Foundation

enum SplitAvailability {
    @MainActor
    static var canSplit: Bool { !availableLedgers.isEmpty }

    @MainActor
    static var availableLedgers: [Ledger] { LedgerStore.shared.sharedLedgers }

    /// For background paths that can't reach the MainActor store. Stale by
    /// construction; it only decides whether a choice is offered.
    nonisolated static var hasKnownSharedLedger: Bool {
        UserDefaults.standard.bool(forKey: hasKnownSharedLedgerKey)
    }

    nonisolated static func recordHasSharedLedger(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: hasKnownSharedLedgerKey)
    }

    private nonisolated static let hasKnownSharedLedgerKey = "ledger.hasSharedLedger"
}
