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

    /// The last known answer, for background paths that can't reach the
    /// MainActor store. Stale by construction: its only consequence is whether
    /// the user is offered a choice.
    nonisolated static var hasKnownSharedLedger: Bool {
        UserDefaults.standard.bool(forKey: hasKnownSharedLedgerKey)
    }

    nonisolated static func recordHasSharedLedger(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: hasKnownSharedLedgerKey)
    }

    private nonisolated static let hasKnownSharedLedgerKey = "ledger.hasSharedLedger"
}
