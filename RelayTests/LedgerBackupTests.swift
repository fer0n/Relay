//
//  LedgerBackupTests.swift
//  RelayTests
//
//  The backup is the only independent record of a ledger, so its integrity
//  data has to catch a file that no longer matches what it claims — and the
//  cross-reference has to stay quiet about a live ledger that has simply
//  moved on since.
//

import CloudKit
import Foundation
import Testing
@testable import Relay

struct LedgerBackupTests {
    private static func ledger(zoneName: String = "Ledger-1") -> Ledger {
        Ledger(
            zoneID: CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName),
            name: "Trip",
            currencyCode: "EUR",
            createdAt: Date(timeIntervalSince1970: 1_600_000_000),
            isOwnedByCurrentUser: true,
            participants: [
                LedgerParticipant(id: "me", name: "Me", isCurrentUser: true, hasAccepted: true, isOwner: true),
                LedgerParticipant(id: "you", name: "You", isCurrentUser: false, hasAccepted: true, isOwner: false),
            ]
        )
    }

    private static func expense(
        id: String = "e1",
        cents: Int = 1000,
        date: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> LedgerExpense {
        LedgerExpense(
            id: id,
            title: "Dinner",
            costCents: cents,
            currencyCode: "EUR",
            date: date,
            shares: [
                LedgerExpenseShare(participantID: "me", paidCents: cents, owedCents: cents / 2),
                LedgerExpenseShare(participantID: "you", paidCents: 0, owedCents: cents - cents / 2),
            ]
        )
    }

    private static func backup(
        expenses: [LedgerExpense],
        zoneName: String = "Ledger-1"
    ) -> LedgerBackup {
        LedgerBackup(
            ledgers: [ledger(zoneName: zoneName)],
            expenses: [zoneName: expenses],
            currentUserID: "me"
        )
    }

    @Test
    func recordsTotalsAndNetsPerLedger() throws {
        let backup = Self.backup(expenses: [Self.expense(), Self.expense(id: "e2", cents: 500)])
        let check = try #require(backup.ledgers.first).check

        #expect(check.expenseCount == 2)
        #expect(check.totalCents == 1500)
        #expect(check.netCentsByParticipant["me"] == 750)
        #expect(check.netCentsByParticipant["you"] == -750)
    }

    @Test
    func verifiesAnUntouchedBackup() {
        let verification = LedgerBackupVerifier.verify(Self.backup(expenses: [Self.expense()]))

        #expect(verification.isValid)
        #expect(verification.expenseCount == 1)
    }

    @Test
    func survivesAJSONRoundTrip() throws {
        let original = Self.backup(expenses: [Self.expense(), Self.expense(id: "e2", cents: 333)])
        let data = try BackupService.encode(
            BackupService.makeBackup(ledgers: original, deviceName: "iPhone")
        )
        let decoded = try #require(BackupService.decodeBackup(from: data))
        let ledgers = try #require(decoded.ledgers)

        #expect(LedgerBackupVerifier.verify(ledgers).isValid)
        #expect(decoded.deviceName == "iPhone")
    }

    /// The failure this whole section exists to catch: a file whose expenses
    /// no longer add up to the totals stored beside them.
    @Test
    func catchesAnAlteredExpense() {
        var backup = Self.backup(expenses: [Self.expense()])
        backup.ledgers[0].expenses[0] = Self.expense(cents: 2000)

        let verification = LedgerBackupVerifier.verify(backup)

        #expect(!verification.isValid)
        #expect(verification.problems.contains(.digestMismatch(zoneName: "Ledger-1")))
        #expect(verification.problems.contains(.totalMismatch(zoneName: "Ledger-1", recorded: 1000, actual: 2000)))
    }

    @Test
    func crossReferenceAcceptsLiveDataThatHasMovedOn() {
        let backup = Self.backup(expenses: [Self.expense()])
        let live = Self.backup(expenses: [Self.expense(), Self.expense(id: "e2", cents: 700)])

        #expect(LedgerBackupVerifier.crossReference(backup, with: live).isValid)
    }

    @Test
    func crossReferenceReportsExpensesTheLiveLedgerLost() {
        let backup = Self.backup(expenses: [Self.expense(), Self.expense(id: "e2", cents: 700)])
        let live = Self.backup(expenses: [Self.expense()])

        let verification = LedgerBackupVerifier.crossReference(backup, with: live)

        #expect(verification.problems == [.missingExpenses(zoneName: "Ledger-1", expenseIDs: ["e2"])])
    }

    @Test
    func crossReferenceReportsALedgerThatIsGone() {
        let backup = Self.backup(expenses: [Self.expense()])
        let live = LedgerBackup(ledgers: [], expenses: [:], currentUserID: "me")

        #expect(
            LedgerBackupVerifier.crossReference(backup, with: live).problems
                == [.missingLedger(zoneName: "Ledger-1")]
        )
    }

    /// Same expense edited on both sides: nothing is missing, but the two
    /// copies disagree.
    @Test
    func crossReferenceReportsAnEditedExpense() {
        let backup = Self.backup(expenses: [Self.expense()])
        let live = Self.backup(expenses: [Self.expense(cents: 4000)])

        #expect(
            LedgerBackupVerifier.crossReference(backup, with: live).problems
                == [.digestMismatch(zoneName: "Ledger-1")]
        )
    }
}
