//
//  LedgerNotificationSummaryTests.swift
//  RelayTests
//
//  The one line of a split notification anyone actually reads. Its ordering
//  isn't cosmetic: the reader's own share is the reason they'd look at all, so
//  it goes first, and everything after it is longest-owed first — on a lock
//  screen the tail of the line is what gets truncated away.
//
//  Amounts are matched loosely rather than as literal strings: they're
//  formatted in the runner's locale, and pinning "1,50 €" here would fail on a
//  machine set to anything but German.
//

import CloudKit
import Foundation
import Testing
@testable import Relay

@MainActor
struct LedgerNotificationSummaryTests {
    private static let me = LedgerParticipant(
        id: "me", name: "Michi Foerg", isCurrentUser: true, hasAccepted: true, isOwner: true
    )
    private static let michaela = LedgerParticipant(
        id: "michaela", name: "Michaela Martin", isCurrentUser: false, hasAccepted: true, isOwner: false
    )
    private static let sam = LedgerParticipant(
        id: "sam", name: "Sam Reyes", isCurrentUser: false, hasAccepted: true, isOwner: false
    )

    private static func ledger(_ participants: [LedgerParticipant]) -> Ledger {
        Ledger(
            zoneID: .init(zoneName: "Ledger-1", ownerName: "_owner"),
            name: "Flat",
            currencyCode: "EUR",
            createdAt: Date(),
            isOwnedByCurrentUser: true,
            participants: participants
        )
    }

    private static func expense(_ shares: [LedgerExpenseShare], costCents: Int) -> LedgerExpense {
        LedgerExpense(
            title: "Edeka",
            costCents: costCents,
            currencyCode: "EUR",
            date: Date(),
            shares: shares
        )
    }

    /// The reader is "You" even though their profile has a name on it — the
    /// summary is a list they're one of.
    @Test
    func theReaderComesFirstAndIsCalledYou() {
        let expense = Self.expense([
            LedgerExpenseShare(participantID: "michaela", paidCents: 300, owedCents: 150),
            LedgerExpenseShare(participantID: "me", paidCents: 0, owedCents: 150),
        ], costCents: 300)

        let summary = LedgerChangeNotifier.splitSummary(
            of: expense,
            in: Self.ledger([Self.me, Self.michaela]),
            currentUserID: "me"
        )

        #expect(summary.hasPrefix("You: "))
        #expect(summary.contains(" • Michaela: "))
    }

    /// Everyone else is ordered by what they owe, so the share most worth
    /// seeing survives being truncated.
    @Test
    func othersAreOrderedByWhatTheyOwe() {
        let expense = Self.expense([
            LedgerExpenseShare(participantID: "me", paidCents: 1000, owedCents: 100),
            LedgerExpenseShare(participantID: "sam", paidCents: 0, owedCents: 200),
            LedgerExpenseShare(participantID: "michaela", paidCents: 0, owedCents: 700),
        ], costCents: 1000)

        let summary = LedgerChangeNotifier.splitSummary(
            of: expense,
            in: Self.ledger([Self.me, Self.michaela, Self.sam]),
            currentUserID: "me"
        )

        let names = summary.split(separator: " • ").map { $0.split(separator: ":")[0] }
        #expect(names == ["You", "Michaela", "Sam"])
    }

    /// A payer who owes none of it is already named by the total in the title.
    /// Listing them at zero would push a real share off the end of the line.
    @Test
    func someoneWhoOwesNothingIsLeftOut() {
        let expense = Self.expense([
            LedgerExpenseShare(participantID: "me", paidCents: 300, owedCents: 0),
            LedgerExpenseShare(participantID: "michaela", paidCents: 0, owedCents: 300),
        ], costCents: 300)

        let summary = LedgerChangeNotifier.splitSummary(
            of: expense,
            in: Self.ledger([Self.me, Self.michaela]),
            currentUserID: "me"
        )

        #expect(!summary.contains("You"))
        #expect(summary.hasPrefix("Michaela: "))
    }
}
