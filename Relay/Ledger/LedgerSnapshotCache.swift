//
//  LedgerSnapshotCache.swift
//  Relay
//
//  A render cache, not a source of truth: written after a successful refresh,
//  replaced wholesale, never consulted for a write. CloudKit's own local copy
//  is still an async round trip away.
//

import CloudKit
import Foundation

/// `CKRecordZone.ID` isn't `Codable`, so the zone is stored as its two
/// strings and rebuilt on load.
nonisolated struct LedgerSnapshot: Codable, Sendable {
    struct StoredLedger: Codable, Sendable {
        var zoneName: String
        /// A ledger someone else owns is in a zone named after them.
        var zoneOwnerName: String
        var name: String
        var currencyCode: String
        var createdAt: Date
        var isOwnedByCurrentUser: Bool
        var participants: [LedgerParticipant]
        /// Optional so an older cache still decodes; nil is the default "on".
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
    var currentUserID: String?

    init(ledgers: [Ledger], expenses: [String: [LedgerExpense]], currentUserID: String?) {
        self.ledgers = ledgers.map(StoredLedger.init)
        self.expenses = expenses
        self.currentUserID = currentUserID
    }
}
