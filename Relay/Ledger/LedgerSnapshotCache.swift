//
//  LedgerSnapshotCache.swift
//  Relay
//
//  The last known state of every ledger, on disk, so a cold launch draws the
//  pinned balance card immediately.
//
//  CloudKit keeps its own local copy, but reaching it is still an async round
//  trip through `recordZoneChanges`, and until it returns there's nothing to
//  draw. So this is a render cache, not a source of truth: written after a
//  successful refresh, replaced wholesale, never consulted for a write.
//

import CloudKit
import Foundation

/// `Ledger` can't be `Codable` itself — `CKRecordZone.ID` isn't — so the zone
/// is stored as the two strings it's made of and rebuilt on load.
nonisolated struct LedgerSnapshot: Codable, Sendable {
    struct StoredLedger: Codable, Sendable {
        var zoneName: String
        /// Differs between the databases: a ledger someone else owns is in a
        /// zone named after them.
        var zoneOwnerName: String
        var name: String
        var currencyCode: String
        var createdAt: Date
        var isOwnedByCurrentUser: Bool
        var participants: [LedgerParticipant]
        /// Optional only so a cache written before the setting existed still
        /// decodes — a missing value is the same "on" the ledger itself
        /// defaults to.
        var simplifiesDebts: Bool?

        init(_ ledger: Ledger) {
            zoneName = ledger.zoneID.zoneName
            zoneOwnerName = ledger.zoneID.ownerName
            name = ledger.name
            currencyCode = ledger.currencyCode
            createdAt = ledger.createdAt
            isOwnedByCurrentUser = ledger.isOwnedByCurrentUser
            participants = ledger.participants
            simplifiesDebts = ledger.simplifiesDebts
        }

        var ledger: Ledger {
            Ledger(
                zoneID: CKRecordZone.ID(zoneName: zoneName, ownerName: zoneOwnerName),
                name: name,
                currencyCode: currencyCode,
                createdAt: createdAt,
                isOwnedByCurrentUser: isOwnedByCurrentUser,
                participants: participants,
                simplifiesDebts: simplifiesDebts ?? true
            )
        }
    }

    var ledgers: [StoredLedger]
    /// Keyed by zone name, as in the store.
    var expenses: [String: [LedgerExpense]]
    /// So the first frame can already tell whose balance it's showing.
    var currentUserID: String?

    init(ledgers: [Ledger], expenses: [String: [LedgerExpense]], currentUserID: String?) {
        self.ledgers = ledgers.map(StoredLedger.init)
        self.expenses = expenses
        self.currentUserID = currentUserID
    }
}
