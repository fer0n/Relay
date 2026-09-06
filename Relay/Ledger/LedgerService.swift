//
//  LedgerService.swift
//  Relay
//
//  CloudKit client. One zone per ledger, shared zone-wide so any participant
//  can add expenses; read via `recordZoneChanges`, which needs no queryable
//  indexes and is immediately consistent.
//

import CloudKit
import Foundation
import os

enum LedgerError: Error {
    case iCloudUnavailable(CKAccountStatus)
    /// Shares must be created and managed by the zone's owner.
    case notOwner
    /// Shares don't add up to the cost.
    case unbalanced
    case notFound
}

nonisolated enum LedgerService {
    /// Must match `Relay.entitlements`.
    static let containerIdentifier = "iCloud.\(Const.bundleID)"

    private static let logger = Logger(subsystem: Const.loggerSubsystem, category: "Ledger")

    static var container: CKContainer { CKContainer(identifier: containerIdentifier) }

    // MARK: - Account

    static func accountStatus() async throws -> CKAccountStatus {
        try await container.accountStatus()
    }

    /// What expense shares are keyed by, on every device.
    static func currentUserID() async throws -> String {
        let status = try await accountStatus()
        guard status == .available else { throw LedgerError.iCloudUnavailable(status) }
        return try await container.userRecordID().recordName
    }

    // MARK: - Ledgers

    /// Owned and accepted-share ledgers, both databases in parallel.
    static func fetchLedgers() async throws -> [Ledger] {
        let currentUserID = try await currentUserID()
        async let owned = ledgers(in: container.privateCloudDatabase, isOwned: true, currentUserID: currentUserID)
        async let shared = ledgers(in: container.sharedCloudDatabase, isOwned: false, currentUserID: currentUserID)
        return try await (owned + shared).sorted { $0.createdAt < $1.createdAt }
    }

    private static func ledgers(
        in database: CKDatabase,
        isOwned: Bool,
        currentUserID: String
    ) async throws -> [Ledger] {
        let zones = try await database.allRecordZones().filter { LedgerRecords.isLedgerZone($0.zoneID) }
        // Two round trips each; in sequence that's a visible wait per refresh.
        return await withTaskGroup(of: Ledger?.self) { group in
            for zone in zones {
                group.addTask {
                    await ledger(in: zone.zoneID, database: database, isOwned: isOwned, currentUserID: currentUserID)
                }
            }
            return await group.reduce(into: []) { result, ledger in
                if let ledger { result.append(ledger) }
            }
        }
    }

    /// Nil for a zone whose meta record hasn't synced yet.
    private static func ledger(
        in zoneID: CKRecordZone.ID,
        database: CKDatabase,
        isOwned: Bool,
        currentUserID: String
    ) async -> Ledger? {
        async let meta = try? database.record(for: LedgerRecords.metaRecordID(in: zoneID))
        async let share = try? zoneWideShare(in: zoneID, database: database)
        guard let meta = await meta else {
            logger.notice("Skipping ledger zone with no meta record")
            return nil
        }
        return LedgerRecords.ledger(
            from: meta,
            isOwnedByCurrentUser: isOwned,
            participants: participants(of: await share, currentUserID: currentUserID, isOwned: isOwned)
        )
    }

    /// Starts unshared: a half-finished setup leaves a private list, not a
    /// live invite.
    static func createLedger(name: String, currencyCode: String) async throws -> Ledger {
        let currentUserID = try await currentUserID()
        let zoneID = LedgerRecords.newZoneID()
        let database = container.privateCloudDatabase
        _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
        let meta = LedgerRecords.makeMetaRecord(name: name, currencyCode: currencyCode, in: zoneID)
        let saved = try await database.save(meta)
        return LedgerRecords.ledger(
            from: saved,
            isOwnedByCurrentUser: true,
            participants: participants(of: nil, currentUserID: currentUserID, isOwned: true)
        )
    }

    /// Any participant may rename the meta record; the share's own title is
    /// the owner's to change, so that half is best-effort.
    static func rename(_ ledger: Ledger, to name: String) async throws {
        let database = self.database(for: ledger)
        let recordID = LedgerRecords.metaRecordID(in: ledger.zoneID)
        guard let record = try? await database.record(for: recordID) else { throw LedgerError.notFound }
        record[LedgerRecords.MetaField.name] = name as CKRecordValue
        _ = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .changedKeys)
        guard ledger.isOwnedByCurrentUser,
              let share = try? await zoneWideShare(in: ledger.zoneID, database: database) else { return }
        share[CKShare.SystemFieldKey.title] = name as CKRecordValue
        _ = try? await database.modifyRecords(saving: [share], deleting: [], savePolicy: .changedKeys)
    }

    /// On the meta record, so everyone on the ledger sees the same balances.
    static func setSimplifiesDebts(_ simplifies: Bool, in ledger: Ledger) async throws {
        let database = self.database(for: ledger)
        let recordID = LedgerRecords.metaRecordID(in: ledger.zoneID)
        guard let record = try? await database.record(for: recordID) else { throw LedgerError.notFound }
        record[LedgerRecords.MetaField.simplifyDebts] = (simplifies ? 1 : 0) as CKRecordValue
        _ = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .changedKeys)
    }

    /// Takes every expense and the share with it.
    static func deleteLedger(_ ledger: Ledger) async throws {
        guard ledger.isOwnedByCurrentUser else { throw LedgerError.notOwner }
        _ = try await container.privateCloudDatabase.modifyRecordZones(saving: [], deleting: [ledger.zoneID])
    }

    // MARK: - Expenses

    /// Together: one `recordZoneChanges` walk returns both.
    static func fetchContents(
        in ledger: Ledger,
        currentUserID: String? = nil
    ) async throws -> (expenses: [LedgerExpense], profiles: [String: LedgerProfile]) {
        let currentUserID = if let currentUserID { currentUserID } else { try await self.currentUserID() }
        let database = self.database(for: ledger)
        var expenses: [String: LedgerExpense] = [:]
        var profiles: [String: LedgerProfile] = [:]
        var token: CKServerChangeToken?
        var moreComing = true
        while moreComing {
            let changes = try await database.recordZoneChanges(inZoneWith: ledger.zoneID, since: token)
            for (_, result) in changes.modificationResultsByID {
                guard let record = try? result.get().record else { continue }
                if let expense = LedgerRecords.expense(from: record, currentUserID: currentUserID) {
                    expenses[expense.id] = expense
                } else if let profile = LedgerRecords.profile(from: record) {
                    profiles[profile.participantID] = profile
                }
            }
            for deletion in changes.deletions {
                let name = deletion.recordID.recordName
                expenses[name] = nil
                if let participantID = LedgerRecords.participantID(ofProfile: name) {
                    profiles[participantID] = nil
                }
            }
            token = changes.changeToken
            moreComing = changes.moreComing
        }
        return (expenses.values.sorted(by: LedgerExpense.isOrderedBefore), profiles)
    }

    /// Any participant may write any other's: whoever's name is missing is
    /// precisely who can't supply it.
    static func saveProfile(_ profile: LedgerProfile, in ledger: Ledger) async throws {
        let database = self.database(for: ledger)
        let recordID = LedgerRecords.profileRecordID(for: profile.participantID, in: ledger.zoneID)
        let existing = try? await database.record(for: recordID)
        let record = LedgerRecords.apply(profile, to: existing, in: ledger.zoneID)
        defer { LedgerRecords.deleteStagedAssets(of: record) }
        _ = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .changedKeys)
    }

    /// Refuses an unbalanced expense; CloudKit would store one happily.
    static func save(_ expense: LedgerExpense, in ledger: Ledger) async throws {
        guard expense.isBalanced else { throw LedgerError.unbalanced }
        let database = self.database(for: ledger)
        let recordID = LedgerRecords.recordID(for: expense, in: ledger.zoneID)
        let existing = try? await database.record(for: recordID)
        let record = try LedgerRecords.apply(expense, to: existing, in: ledger.zoneID)
        _ = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged)
    }

    static func delete(_ expense: LedgerExpense, in ledger: Ledger) async throws {
        let recordID = LedgerRecords.recordID(for: expense, in: ledger.zoneID)
        _ = try await database(for: ledger).modifyRecords(saving: [], deleting: [recordID])
    }

    // MARK: - Sharing

    /// The existing zone-wide share or a fresh one. Idempotent.
    static func share(_ ledger: Ledger) async throws -> (CKShare, CKContainer) {
        guard ledger.isOwnedByCurrentUser else { throw LedgerError.notOwner }
        let database = container.privateCloudDatabase
        if let existing = try? await zoneWideShare(in: ledger.zoneID, database: database) {
            return (existing, container)
        }
        let share = CKShare(recordZoneID: ledger.zoneID)
        share[CKShare.SystemFieldKey.title] = ledger.name as CKRecordValue
        // Invite-only: a link share lets anyone join a list of who owes whom.
        share.publicPermission = .none
        let results = try await database.modifyRecords(saving: [share], deleting: [])
        guard let saved = try results.saveResults.values.first?.get() as? CKShare else {
            throw LedgerError.notFound
        }
        return (saved, container)
    }

    /// Deleting from the *shared* database is CloudKit's "remove me"; the
    /// owner's copy is untouched.
    static func leave(_ ledger: Ledger) async throws {
        guard !ledger.isOwnedByCurrentUser else { throw LedgerError.notOwner }
        _ = try await container.sharedCloudDatabase.modifyRecordZones(saving: [], deleting: [ledger.zoneID])
    }

    private static func zoneWideShare(in zoneID: CKRecordZone.ID, database: CKDatabase) async throws -> CKShare {
        let recordID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        guard let share = try await database.record(for: recordID) as? CKShare else {
            throw LedgerError.notFound
        }
        return share
    }

    /// An unshared ledger still has one participant, so an expense they add
    /// has somebody to attribute the payment to.
    private static func participants(
        of share: CKShare?,
        currentUserID: String,
        isOwned: Bool
    ) -> [LedgerParticipant] {
        guard let share else {
            // Nil, not "You": `displayName` localizes that, and a literal
            // here would prefill the profile editor with it.
            return [LedgerParticipant(
                id: currentUserID,
                name: nil,
                isCurrentUser: true,
                hasAccepted: true,
                isOwner: isOwned
            )]
        }
        let ownerID = LedgerRecords.resolving(
            share.owner.userIdentity.userRecordID?.recordName,
            as: currentUserID
        )
        return share.participants.compactMap { participant in
            // `currentUserParticipant` can't identify anyone: the reader is
            // described to themselves as the placeholder.
            guard let id = LedgerRecords.resolving(
                participant.userIdentity.userRecordID?.recordName,
                as: currentUserID
            ) else { return nil }
            // Removed participants stay in the list with this status.
            guard participant.acceptanceStatus != .removed else { return nil }
            // The link-share placeholder has no identity behind it.
            guard participant.role != .publicUser else { return nil }
            return LedgerParticipant(
                id: id,
                name: name(of: participant),
                isCurrentUser: id == currentUserID,
                hasAccepted: participant.acceptanceStatus == .accepted,
                isOwner: id == ownerID
            )
        }
    }

    /// Before `nameComponents` resolves, the invite handle is all there is.
    private static func name(of participant: CKShare.Participant) -> String {
        let identity = participant.userIdentity
        if let components = identity.nameComponents {
            let formatted = PersonNameComponentsFormatter.localizedString(from: components, style: .default)
            if !formatted.isEmpty { return formatted }
        }
        if let email = identity.lookupInfo?.emailAddress { return email }
        if let phone = identity.lookupInfo?.phoneNumber { return phone }
        return LedgerParticipant.unknownName
    }

    private static func database(for ledger: Ledger) -> CKDatabase {
        ledger.isOwnedByCurrentUser ? container.privateCloudDatabase : container.sharedCloudDatabase
    }
}
