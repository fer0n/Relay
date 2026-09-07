//
//  ImportedRowLedgerMatcherTests.swift
//  RelayTests
//

import Foundation
import Testing
@testable import Relay

@MainActor
struct ImportedRowLedgerMatcherTests {
    private static let day = TimeInterval(86_400)
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func row(id: String, amount: Double, dayOffset: Double = 0) -> FileImportRow {
        FileImportRow(
            id: id,
            date: Self.base.addingTimeInterval(dayOffset * Self.day),
            payeeName: "ACME",
            memo: nil,
            amount: amount
        )
    }

    private func expense(cents: Int, dayOffset: Double = 0, isSettlement: Bool = false) -> LedgerExpense {
        LedgerExpense(
            title: "ACME",
            costCents: cents,
            currencyCode: "EUR",
            date: Self.base.addingTimeInterval(dayOffset * Self.day),
            shares: [],
            isSettlement: isSettlement
        )
    }

    @Test func matchesSameAmountWithinTolerance() {
        let rows = [row(id: "a", amount: -12.34, dayOffset: 2)]
        let matched = ImportedRowLedgerMatcher.likelyExistingIDs(rows: rows, expenses: [expense(cents: 1234)])
        #expect(matched == ["a"])
    }

    @Test func ignoresDistantDatesAndOtherAmounts() {
        let rows = [row(id: "far", amount: 12.34, dayOffset: 9), row(id: "other", amount: 20)]
        let matched = ImportedRowLedgerMatcher.likelyExistingIDs(rows: rows, expenses: [expense(cents: 1234)])
        #expect(matched.isEmpty)
    }

    @Test func oneExpenseClaimsOneRow() {
        let matched = ImportedRowLedgerMatcher.likelyExistingIDs(
            rows: [row(id: "a", amount: 5), row(id: "b", amount: 5, dayOffset: 1)],
            expenses: [expense(cents: 500)]
        )
        #expect(matched == ["a"])
    }

    @Test func skipsSettlements() {
        let matched = ImportedRowLedgerMatcher.likelyExistingIDs(
            rows: [row(id: "a", amount: 5)],
            expenses: [expense(cents: 500, isSettlement: true)]
        )
        #expect(matched.isEmpty)
    }
}
