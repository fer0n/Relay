//
//  LedgerRecords.swift
//  Relay
//
//  The CKRecord ↔ model boundary, apart from `LedgerService` so the wire
//  format is round-trip testable without the network.
//
//  Field names are frozen once a build ships — CloudKit can't rename a
//  deployed field, and older builds keep writing the old shape — so every
//  read here falls back rather than failing the record.
//

import CloudKit
import Foundation

nonisolated enum LedgerRecords {
    enum RecordType {
        static let meta = "LedgerMeta"
        static let expense = "LedgerExpense"
        static let profile = "LedgerProfile"
    }

    /// A constant name so the singleton is a plain fetch: cheaper than a
    /// query, and immediately consistent where a query isn't.
    static let metaRecordName = "meta"

    enum MetaField {
        static let name = "name"
        static let currencyCode = "currencyCode"
        static let createdAt = "createdAt"
        /// Stored as an Int — CloudKit has no boolean field type. Absent on
        /// every ledger made before the setting existed, which reads as on.
        static let simplifyDebts = "simplifyDebts"
    }

    enum ExpenseField {
        static let title = "title"
        static let costCents = "costCents"
        static let currencyCode = "currencyCode"
        static let date = "date"
        /// JSON, not three parallel lists: keeping those in step is exactly
        /// the skew that would silently corrupt a balance.
        static let shares = "shares"
        /// Stored as an Int — CloudKit has no boolean field type.
        static let isSettlement = "isSettlement"
    }

    /// What CloudKit puts in place of the reader's *own* record name,
    /// everywhere it names a user. It means "me", so it means a different
    /// person on every device — never store it. Everything read out of
    /// CloudKit goes through `resolving(_:as:)` first.
    static let currentUserPlaceholder = CKCurrentUserDefaultName

    static func resolving(_ recordName: String?, as currentUserID: String) -> String? {
        recordName == currentUserPlaceholder ? currentUserID : recordName
    }

    enum ProfileField {
        static let displayName = "displayName"
        /// A `CKAsset`: CloudKit caps a record's own fields at 1 MB.
        static let image = "image"
        static let updatedAt = "updatedAt"
    }

    /// Prefixed so `allRecordZones()` can be filtered without fetching each
    /// zone's contents.
    static let zoneNamePrefix = "Ledger-"

    static func newZoneID() -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zoneNamePrefix + UUID().uuidString, ownerName: CKCurrentUserDefaultName)
    }

    static func isLedgerZone(_ zoneID: CKRecordZone.ID) -> Bool {
        zoneID.zoneName.hasPrefix(zoneNamePrefix)
    }

    static func metaRecordID(in zoneID: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: metaRecordName, zoneID: zoneID)
    }

    // MARK: - Meta

    static func makeMetaRecord(name: String, currencyCode: String, in zoneID: CKRecordZone.ID) -> CKRecord {
        let record = CKRecord(recordType: RecordType.meta, recordID: metaRecordID(in: zoneID))
        record[MetaField.name] = name as CKRecordValue
        record[MetaField.currencyCode] = currencyCode as CKRecordValue
        record[MetaField.createdAt] = Date() as CKRecordValue
        record[MetaField.simplifyDebts] = 1 as CKRecordValue
        return record
    }

    /// Falls back rather than returning nil: the zone holds expenses either
    /// way, and losing it over one absent string is worse.
    static func ledger(
        from record: CKRecord,
        isOwnedByCurrentUser: Bool,
        participants: [LedgerParticipant]
    ) -> Ledger {
        Ledger(
            zoneID: record.recordID.zoneID,
            name: record[MetaField.name] as? String ?? "Shared Expenses",
            currencyCode: record[MetaField.currencyCode] as? String ?? Const.currencyCode,
            createdAt: record[MetaField.createdAt] as? Date ?? record.creationDate ?? Date(),
            isOwnedByCurrentUser: isOwnedByCurrentUser,
            participants: participants,
            simplifiesDebts: (record[MetaField.simplifyDebts] as? Int).map { $0 != 0 } ?? true
        )
    }

    // MARK: - Profile

    static func profileRecordID(for participantID: String, in zoneID: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: profileRecordName(for: participantID), zoneID: zoneID)
    }

    static func profileRecordName(for participantID: String) -> String {
        profileRecordPrefix + participantID
    }

    static func apply(_ profile: LedgerProfile, to existing: CKRecord?, in zoneID: CKRecordZone.ID) -> CKRecord {
        let record = existing ?? CKRecord(
            recordType: RecordType.profile,
            recordID: profileRecordID(for: profile.participantID, in: zoneID)
        )
        record[ProfileField.displayName] = profile.displayName as CKRecordValue?
        record[ProfileField.image] = profile.imageData.flatMap(imageAsset(from:))
        record[ProfileField.updatedAt] = Date() as CKRecordValue
        return record
    }

    /// Stages the JPEG where `CKAsset` can read it. Nil rather than throwing:
    /// a picture that can't be written is worth losing silently next to the
    /// name it accompanies.
    ///
    /// The caller owns the file — CloudKit only reads it during the save — so
    /// `deleteStagedAssets(of:)` clears it afterwards rather than leaving a
    /// copy of every picture ever picked in tmp.
    private static func imageAsset(from data: Data) -> CKAsset? {
        let url = stagingDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        try? FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        guard (try? data.write(to: url)) != nil else { return nil }
        return CKAsset(fileURL: url)
    }

    private static var stagingDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ledger-assets", isDirectory: true)
    }

    static func deleteStagedAssets(of record: CKRecord) {
        guard let url = (record[ProfileField.image] as? CKAsset)?.fileURL,
              url.deletingLastPathComponent() == stagingDirectory else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func profile(from record: CKRecord) -> LedgerProfile? {
        guard record.recordType == RecordType.profile else { return nil }
        let name = (record[ProfileField.displayName] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let imageData = (record[ProfileField.image] as? CKAsset)?.fileURL
            .flatMap { try? Data(contentsOf: $0) }
        guard let participantID = participantID(ofProfile: record.recordID.recordName) else { return nil }
        return LedgerProfile(
            participantID: participantID,
            displayName: (name?.isEmpty ?? true) ? nil : name,
            imageData: imageData
        )
    }

    static let profileRecordPrefix = "profile-"

    /// Nil for a record name that isn't a profile's, so a deletion of some
    /// other record can't be mistaken for one.
    static func participantID(ofProfile recordName: String) -> String? {
        guard recordName.hasPrefix(profileRecordPrefix) else { return nil }
        return String(recordName.dropFirst(profileRecordPrefix.count))
    }

    // MARK: - Expense

    static func recordID(for expense: LedgerExpense, in zoneID: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: expense.id, zoneID: zoneID)
    }

    /// Editing must mutate the record CloudKit handed back: a fresh one
    /// carries no change tag and the save is rejected as a conflict.
    static func apply(_ expense: LedgerExpense, to existing: CKRecord?, in zoneID: CKRecordZone.ID) throws -> CKRecord {
        let record = existing ?? CKRecord(
            recordType: RecordType.expense,
            recordID: recordID(for: expense, in: zoneID)
        )
        record[ExpenseField.title] = expense.title as CKRecordValue
        record[ExpenseField.costCents] = expense.costCents as CKRecordValue
        record[ExpenseField.currencyCode] = expense.currencyCode as CKRecordValue
        record[ExpenseField.date] = expense.date as CKRecordValue
        record[ExpenseField.shares] = try JSONEncoder().encode(expense.shares) as CKRecordValue
        record[ExpenseField.isSettlement] = (expense.isSettlement ? 1 : 0) as CKRecordValue
        return record
    }

    /// A share blob that won't decode yields an expense with no shares rather
    /// than dropping the row, which would quietly change everyone's balance.
    static func expense(from record: CKRecord, currentUserID: String) -> LedgerExpense? {
        guard record.recordType == RecordType.expense else { return nil }
        let stored = (record[ExpenseField.shares] as? Data)
            .flatMap { try? JSONDecoder().decode([LedgerExpenseShare].self, from: $0) } ?? []
        // Whoever wrote the record is who its "me" placeholder meant; nil
        // means the reader wrote it.
        let author = resolving(record.creatorUserRecordID?.recordName, as: currentUserID) ?? currentUserID
        let shares = resolvingPlaceholders(in: stored, writtenBy: author)
        return LedgerExpense(
            id: record.recordID.recordName,
            title: record[ExpenseField.title] as? String ?? "",
            costCents: record[ExpenseField.costCents] as? Int ?? 0,
            currencyCode: record[ExpenseField.currencyCode] as? String ?? Const.currencyCode,
            date: record[ExpenseField.date] as? Date ?? record.creationDate ?? Date(),
            shares: shares,
            isSettlement: (record[ExpenseField.isSettlement] as? Int ?? 0) != 0,
            createdBy: author,
            createdAt: record.creationDate ?? Date()
        )
    }

    /// Repairs shares from a build that stored the "me" placeholder. Read-only
    /// on purpose, so a device on the old build keeps reading what it wrote.
    private static func resolvingPlaceholders(
        in shares: [LedgerExpenseShare],
        writtenBy author: String
    ) -> [LedgerExpenseShare] {
        guard shares.contains(where: { $0.participantID == currentUserPlaceholder }) else { return shares }
        return shares.map { share in
            guard share.participantID == currentUserPlaceholder else { return share }
            return LedgerExpenseShare(
                participantID: author,
                paidCents: share.paidCents,
                owedCents: share.owedCents
            )
        }
    }
}
