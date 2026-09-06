//
//  SplitEntryTests.swift
//  RelayTests
//
//  The gate every split goes through before a ledger write: the share the
//  user typed, and the pickers' memory of who they usually split with. A
//  share validated too late is the bad case — the YNAB transaction is already
//  created by then, and there'd be no split to match it.
//

import Foundation
import Testing
@testable import Relay

struct SplitOwnShareTests {
    /// The whole point of validating separately: the callers that create a
    /// YNAB transaction *and* a split check this before doing either.
    @Test func aShareWithinTheTotalPasses() throws {
        try SplitExpenseService.validateOwnShare(0, amount: 20)
        try SplitExpenseService.validateOwnShare(10, amount: 20)
        try SplitExpenseService.validateOwnShare(20, amount: 20)
    }

    @Test func aShareOutsideTheTotalIsRejected() {
        #expect(throws: LedgerExpenseError.self) {
            try SplitExpenseService.validateOwnShare(-1, amount: 20)
        }
        #expect(throws: LedgerExpenseError.self) {
            try SplitExpenseService.validateOwnShare(20.01, amount: 20)
        }
    }

    /// A Shortcut can hand over anything a number field allows.
    @Test func aNonFiniteShareIsRejected() {
        #expect(throws: LedgerExpenseError.self) {
            try SplitExpenseService.validateOwnShare(.nan, amount: 20)
        }
        #expect(throws: LedgerExpenseError.self) {
            try SplitExpenseService.validateOwnShare(.infinity, amount: 20)
        }
    }

    @Test func typedTextBecomesTheShareOrAReason() {
        guard case .valid(let share) = SplitExpenseService.parseOwnShare("7.5", amount: 20) else {
            Issue.record("expected a valid share")
            return
        }
        #expect(share == 7.5)

        for text in ["", "abc", "25", "-1"] {
            guard case .invalid(let message) = SplitExpenseService.parseOwnShare(text, amount: 20) else {
                Issue.record("expected \"\(text)\" to be rejected")
                continue
            }
            #expect(!message.isEmpty)
        }
    }

    /// The share and the split that gets built from it have to agree on what
    /// a rounding case comes to, or an expense passes validation and then
    /// fails `isBalanced` at the write.
    @Test func aValidatedShareAlwaysBuildsABalancedExpense() throws {
        for (amount, ownShare) in [(10.0, 3.33), (0.03, 0.01), (99.99, 0.0), (20.0, 20.0)] {
            try SplitExpenseService.validateOwnShare(ownShare, amount: amount)
            let costCents = SplitShareMath.cents(fromAmount: amount)
            let shares = try #require(LedgerBalanceMath.shares(
                costCents: costCents,
                payerID: "me",
                participantIDs: ["me", "alex", "sam"],
                allocation: .ownShare(cents: SplitShareMath.cents(fromAmount: ownShare))
            ))
            let expense = LedgerExpense(
                title: "Dinner",
                costCents: costCents,
                currencyCode: "EUR",
                date: Date(),
                shares: shares
            )
            #expect(expense.isBalanced, "\(amount) with own share \(ownShare)")
        }
    }
}

struct LedgerParticipantOrderTests {
    private static func participant(_ id: String) -> LedgerParticipant {
        LedgerParticipant(id: id, name: id.capitalized, isCurrentUser: false, hasAccepted: true, isOwner: false)
    }

    /// Recently split-with people come first — CloudKit's own order is
    /// arbitrary, and the picker is the first thing the split form shows.
    @Test func recentlySplitWithPeopleComeFirst() {
        let people = [Self.participant("alex"), Self.participant("sam"), Self.participant("robin")]
        let sorted = UsageStore.sorted(
            people,
            lastUsed: [
                "robin": Date(timeIntervalSince1970: 200),
                "alex": Date(timeIntervalSince1970: 100),
            ],
            key: \.id
        )
        // Never split with, so last — behind both people who have been.
        #expect(sorted.map(\.id) == ["robin", "alex", "sam"])
    }

    /// Two people never split with keep the order they arrived in, so the
    /// list doesn't reshuffle itself between launches.
    @Test func peopleWithNoHistoryKeepTheirOrder() {
        let people = [Self.participant("alex"), Self.participant("sam")]
        #expect(UsageStore.sorted(people, lastUsed: [:], key: \.id).map(\.id) == ["alex", "sam"])
    }

    /// Restoring an older backup must not demote someone still being split
    /// with, so a merge keeps the later date per person.
    @Test func mergingUsageKeepsTheLaterDate() {
        // Ids nothing else uses, since this writes to the real usage file the
        // way the app does.
        let recent = "test-recent-\(UUID().uuidString)"
        let fresh = "test-fresh-\(UUID().uuidString)"
        let now = Date()

        LedgerParticipantUsageStore.recordUsage(participantIDs: [recent])
        var older = LedgerParticipantUsage()
        older.lastUsedByParticipantID = [
            recent: Date(timeIntervalSince1970: 1),
            fresh: now,
        ]
        LedgerParticipantUsageStore.merge(older)

        let loaded = LedgerParticipantUsageStore.load().lastUsedByParticipantID
        #expect(loaded[recent] ?? .distantPast > Date(timeIntervalSince1970: 1))
        // Somebody the backup knows about and this device doesn't is still
        // worth keeping.
        #expect(loaded[fresh] == now)
    }
}

struct DefaultSplitTargetStoreTests {
    private static let target = WalletTransactionConfig.CachedSplitTarget(
        zoneName: "Ledger-1",
        participantID: "alex",
        firstName: "Alex",
        fullName: "Alex Meyer"
    )

    /// Restores whatever was there, so a run can't change the app's own
    /// default.
    private func restoringDefault(_ body: () throws -> Void) throws {
        let previous = DefaultSplitTargetStore.load()
        defer {
            if let previous {
                try? DefaultSplitTargetStore.save(previous)
            } else {
                DefaultSplitTargetStore.clear()
            }
        }
        try body()
    }

    /// It's stored as a mirror rather than by making the picker's type
    /// Codable, which is exactly the arrangement that loses a field quietly.
    @Test func theDefaultTargetRoundTrips() throws {
        try restoringDefault {
            try DefaultSplitTargetStore.save(Self.target)
            let loaded = DefaultSplitTargetStore.load()
            #expect(loaded?.zoneName == Self.target.zoneName)
            #expect(loaded?.participantID == Self.target.participantID)
            #expect(loaded?.firstName == Self.target.firstName)
            #expect(loaded?.fullName == Self.target.fullName)
        }
    }

    /// A whole-ledger default has no participant, and reading one back with
    /// an id would bill one person for a split meant for everyone.
    @Test func aWholeLedgerDefaultKeepsNoParticipant() throws {
        try restoringDefault {
            try DefaultSplitTargetStore.save(WalletTransactionConfig.CachedSplitTarget(
                zoneName: "Ledger-1",
                participantID: nil,
                firstName: "Trip",
                fullName: "Trip"
            ))
            #expect(DefaultSplitTargetStore.load()?.participantID == nil)
        }
    }

    @Test func clearingLeavesNoDefault() throws {
        try restoringDefault {
            try DefaultSplitTargetStore.save(Self.target)
            DefaultSplitTargetStore.clear()
            #expect(DefaultSplitTargetStore.load() == nil)
        }
    }
}
