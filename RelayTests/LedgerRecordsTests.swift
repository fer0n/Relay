//
//  LedgerRecordsTests.swift
//  RelayTests
//
//  The CKRecord ↔ model boundary, which nothing else covers: it's the one
//  place a schema rule gets broken silently. The two that matter most are
//  CloudKit's "me" placeholder — stored, it bills whoever opens the ledger —
//  and a field read strictly, which loses a whole expense the moment a build
//  writes a shape this one didn't expect.
//

import CloudKit
import Foundation
import Testing
@testable import Relay

struct LedgerRecordsTests {
    private static let zoneID = CKRecordZone.ID(zoneName: "Ledger-abc", ownerName: "owner")

    private static func expense(
        id: String = "expense-1",
        title: String = "Dinner",
        costCents: Int = 3000,
        isSettlement: Bool = false
    ) -> LedgerExpense {
        LedgerExpense(
            id: id,
            title: title,
            costCents: costCents,
            currencyCode: "EUR",
            date: Date(timeIntervalSince1970: 1_700_000_000),
            shares: [
                LedgerExpenseShare(participantID: "me", paidCents: costCents, owedCents: 1000),
                LedgerExpenseShare(participantID: "alex", paidCents: 0, owedCents: costCents - 1000),
            ],
            isSettlement: isSettlement
        )
    }

    // MARK: - Expenses

    /// Everything an expense carries has to survive the wire, shares
    /// included: they're a JSON blob, so a change there fails silently rather
    /// than at compile time.
    @Test func anExpenseRoundTripsThroughItsRecord() throws {
        let original = Self.expense()
        let record = try LedgerRecords.apply(original, to: nil, in: Self.zoneID)
        let restored = try #require(LedgerRecords.expense(from: record, currentUserID: "me"))

        #expect(restored.id == original.id)
        #expect(restored.title == original.title)
        #expect(restored.costCents == original.costCents)
        #expect(restored.currencyCode == original.currencyCode)
        #expect(restored.date == original.date)
        #expect(restored.shares == original.shares)
        #expect(restored.isSettlement == false)
        #expect(restored.isBalanced)
    }

    /// Stored as an Int, since CloudKit has no boolean — a settlement that
    /// came back ordinary would relabel the row.
    @Test func aSettlementSurvivesAsOne() throws {
        let record = try LedgerRecords.apply(Self.expense(isSettlement: true), to: nil, in: Self.zoneID)
        #expect(record[LedgerRecords.ExpenseField.isSettlement] as? Int == 1)
        #expect(LedgerRecords.expense(from: record, currentUserID: "me")?.isSettlement == true)
    }

    /// The record CloudKit handed back has to be the one that's mutated: a
    /// fresh one carries no change tag and the save comes back a conflict.
    @Test func anEditReusesTheRecordCloudKitHandedBack() throws {
        let existing = try LedgerRecords.apply(Self.expense(), to: nil, in: Self.zoneID)
        var edited = Self.expense()
        edited.title = "Lunch"
        let updated = try LedgerRecords.apply(edited, to: existing, in: Self.zoneID)

        #expect(updated === existing)
        #expect(updated[LedgerRecords.ExpenseField.title] as? String == "Lunch")
    }

    /// The record's own name is the expense's id, so an edit overwrites
    /// rather than adding a second copy.
    @Test func theRecordIsNamedAfterTheExpense() throws {
        let record = try LedgerRecords.apply(Self.expense(id: "abc"), to: nil, in: Self.zoneID)
        #expect(record.recordID.recordName == "abc")
        #expect(record.recordID.zoneID == Self.zoneID)
    }

    /// Fields are frozen once deployed, so an older build's record is missing
    /// whatever came later. Falling back keeps the row; failing would drop an
    /// expense out of everyone's balance.
    @Test func aRecordWithNoFieldsSetStillReadsAsAnExpense() {
        let record = CKRecord(
            recordType: LedgerRecords.RecordType.expense,
            recordID: CKRecord.ID(recordName: "bare", zoneID: Self.zoneID)
        )
        let restored = LedgerRecords.expense(from: record, currentUserID: "me")

        #expect(restored?.title == "")
        #expect(restored?.costCents == 0)
        #expect(restored?.currencyCode == Const.currencyCode)
        #expect(restored?.shares.isEmpty == true)
        #expect(restored?.isSettlement == false)
    }

    /// A blob that won't decode leaves the expense with no shares rather than
    /// dropping the row — a missing row silently changes everyone's balance,
    /// a zero-share one is visible.
    @Test func anUndecodableShareBlobLeavesTheExpenseInPlace() {
        let record = CKRecord(
            recordType: LedgerRecords.RecordType.expense,
            recordID: CKRecord.ID(recordName: "corrupt", zoneID: Self.zoneID)
        )
        record[LedgerRecords.ExpenseField.title] = "Dinner" as CKRecordValue
        record[LedgerRecords.ExpenseField.costCents] = 3000 as CKRecordValue
        record[LedgerRecords.ExpenseField.shares] = Data("not json".utf8) as CKRecordValue

        let restored = LedgerRecords.expense(from: record, currentUserID: "me")
        #expect(restored != nil)
        #expect(restored?.title == "Dinner")
        #expect(restored?.shares.isEmpty == true)
    }

    /// Every record type shares one zone walk, so each reader has to refuse
    /// the others outright.
    @Test func onlyExpenseRecordsReadAsExpenses() {
        for type in [LedgerRecords.RecordType.meta, LedgerRecords.RecordType.profile] {
            let record = CKRecord(
                recordType: type,
                recordID: CKRecord.ID(recordName: "x", zoneID: Self.zoneID)
            )
            #expect(LedgerRecords.expense(from: record, currentUserID: "me") == nil)
        }
    }

    // MARK: - The "me" placeholder

    /// `__defaultOwner__` means "whoever is reading", so it resolves to this
    /// device's user and nothing else does.
    @Test func thePlaceholderResolvesToTheReaderAndNothingElseDoes() {
        #expect(LedgerRecords.resolving(LedgerRecords.currentUserPlaceholder, as: "me") == "me")
        #expect(LedgerRecords.resolving("alex", as: "me") == "alex")
        #expect(LedgerRecords.resolving(nil, as: "me") == nil)
    }

    /// A build that stored the placeholder in a share left a record that bills
    /// whoever opens it. Read back it becomes the record's author — the person
    /// the placeholder meant when it was written.
    @Test func aStoredPlaceholderShareIsRepairedToItsAuthor() throws {
        let record = CKRecord(
            recordType: LedgerRecords.RecordType.expense,
            recordID: CKRecord.ID(recordName: "legacy", zoneID: Self.zoneID)
        )
        record[LedgerRecords.ExpenseField.costCents] = 2000 as CKRecordValue
        record[LedgerRecords.ExpenseField.shares] = try JSONEncoder().encode([
            LedgerExpenseShare(
                participantID: LedgerRecords.currentUserPlaceholder,
                paidCents: 2000,
                owedCents: 1000
            ),
            LedgerExpenseShare(participantID: "alex", paidCents: 0, owedCents: 1000),
        ]) as CKRecordValue

        // A locally built record has no creator, which is CloudKit's way of
        // saying the reader wrote it.
        let restored = try #require(LedgerRecords.expense(from: record, currentUserID: "me"))
        #expect(restored.shares.contains { $0.participantID == "me" && $0.paidCents == 2000 })
        #expect(!restored.shares.contains { $0.participantID == LedgerRecords.currentUserPlaceholder })
        #expect(restored.createdBy == "me")
        #expect(restored.isBalanced)
    }

    /// The repair is read-only: writing an expense back must not turn a
    /// resolved id into the placeholder again.
    @Test func writingNeverStoresThePlaceholder() throws {
        let record = try LedgerRecords.apply(Self.expense(), to: nil, in: Self.zoneID)
        let blob = try #require(record[LedgerRecords.ExpenseField.shares] as? Data)
        let stored = try JSONDecoder().decode([LedgerExpenseShare].self, from: blob)
        #expect(!stored.contains { $0.participantID == LedgerRecords.currentUserPlaceholder })
    }

    // MARK: - Meta

    @Test func aFreshMetaRecordCarriesTheLedgersName() {
        let record = LedgerRecords.makeMetaRecord(name: "Trip", currencyCode: "USD", in: Self.zoneID)
        let ledger = LedgerRecords.ledger(from: record, isOwnedByCurrentUser: true, participants: [])

        #expect(record.recordID.recordName == LedgerRecords.metaRecordName)
        #expect(ledger.name == "Trip")
        #expect(ledger.currencyCode == "USD")
        #expect(ledger.zoneID == Self.zoneID)
        #expect(ledger.isOwnedByCurrentUser)
        #expect(ledger.simplifiesDebts)
    }

    /// Absent on every ledger made before the setting existed, and those
    /// ledgers were showing simplified debts.
    @Test func aMetaRecordWithNoSimplifyFlagSimplifies() {
        let record = CKRecord(
            recordType: LedgerRecords.RecordType.meta,
            recordID: LedgerRecords.metaRecordID(in: Self.zoneID)
        )
        #expect(LedgerRecords.ledger(from: record, isOwnedByCurrentUser: true, participants: []).simplifiesDebts)
    }

    /// Stored as an Int, so only an explicit zero turns it off.
    @Test func simplifyingIsOffOnlyWhenTheFlagSaysZero() {
        let record = CKRecord(
            recordType: LedgerRecords.RecordType.meta,
            recordID: LedgerRecords.metaRecordID(in: Self.zoneID)
        )
        record[LedgerRecords.MetaField.simplifyDebts] = 0 as CKRecordValue
        #expect(!LedgerRecords.ledger(from: record, isOwnedByCurrentUser: true, participants: []).simplifiesDebts)

        record[LedgerRecords.MetaField.simplifyDebts] = 1 as CKRecordValue
        #expect(LedgerRecords.ledger(from: record, isOwnedByCurrentUser: true, participants: []).simplifiesDebts)
    }

    /// The zone holds expenses whether or not the name synced, so losing the
    /// ledger over one absent string is the worse outcome.
    @Test func aMetaRecordWithNoNameStillMakesALedger() {
        let record = CKRecord(
            recordType: LedgerRecords.RecordType.meta,
            recordID: LedgerRecords.metaRecordID(in: Self.zoneID)
        )
        let ledger = LedgerRecords.ledger(from: record, isOwnedByCurrentUser: false, participants: [])
        #expect(!ledger.name.isEmpty)
        #expect(ledger.currencyCode == Const.currencyCode)
        #expect(!ledger.isOwnedByCurrentUser)
    }

    // MARK: - Profiles

    @Test func aProfileRoundTripsThroughItsRecord() {
        let profile = LedgerProfile(participantID: "alex", displayName: "Alex")
        let record = LedgerRecords.apply(profile, to: nil, in: Self.zoneID)
        defer { LedgerRecords.deleteStagedAssets(of: record) }

        #expect(LedgerRecords.profile(from: record) == profile)
    }

    /// A name typed as spaces is nobody's name — it has to read as "not set"
    /// so the members screen keeps offering to set it.
    @Test func aBlankProfileNameReadsAsUnset() {
        let record = CKRecord(
            recordType: LedgerRecords.RecordType.profile,
            recordID: LedgerRecords.profileRecordID(for: "alex", in: Self.zoneID)
        )
        record[LedgerRecords.ProfileField.displayName] = "   " as CKRecordValue
        #expect(LedgerRecords.profile(from: record)?.displayName == nil)

        record[LedgerRecords.ProfileField.displayName] = "  Alex  " as CKRecordValue
        #expect(LedgerRecords.profile(from: record)?.displayName == "Alex")
    }

    /// A deletion arrives as a bare record name, so this is the only thing
    /// telling a profile's from an expense's.
    @Test func onlyAProfilesRecordNameYieldsAParticipant() {
        #expect(LedgerRecords.participantID(ofProfile: LedgerRecords.profileRecordName(for: "alex")) == "alex")
        #expect(LedgerRecords.participantID(ofProfile: LedgerRecords.metaRecordName) == nil)
        #expect(LedgerRecords.participantID(ofProfile: UUID().uuidString) == nil)
    }

    @Test func onlyProfileRecordsReadAsProfiles() throws {
        let expense = try LedgerRecords.apply(Self.expense(), to: nil, in: Self.zoneID)
        #expect(LedgerRecords.profile(from: expense) == nil)
    }

    // MARK: - Zones

    /// The prefix is what lets a refresh filter zones without fetching each
    /// one's contents, so a ledger zone must carry it and nothing else may.
    @Test func onlyPrefixedZonesAreLedgers() {
        #expect(LedgerRecords.isLedgerZone(LedgerRecords.newZoneID()))
        #expect(!LedgerRecords.isLedgerZone(CKRecordZone.default().zoneID))
        #expect(!LedgerRecords.isLedgerZone(CKRecordZone.ID(zoneName: "com.apple.coredata.cloudkit.zone")))
    }

    @Test func everyNewZoneIsItsOwn() {
        #expect(LedgerRecords.newZoneID() != LedgerRecords.newZoneID())
    }
}
