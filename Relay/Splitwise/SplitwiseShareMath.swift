//
//  SplitwiseShareMath.swift
//  Relay
//
//  The arithmetic behind editing an existing expense in
//  SplitwiseExpenseDetailView. Splitwise only accepts an expense whose shares
//  add up to its cost exactly, so changing the total has to redistribute
//  every share — in whole cents, with nothing lost to rounding. Kept out of
//  the view so that rule is testable on its own.
//

import Foundation

nonisolated enum SplitwiseShareMath {
    /// Parses an amount a user typed into whole cents, accepting either
    /// decimal separator (`AmountParser` handles "12.50" and "12,50" alike,
    /// which matters because the field uses a `.decimalPad` whose separator
    /// follows the device locale). Nil for anything unparseable or negative —
    /// a share can be zero, but never below it.
    static func cents(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let value = try? AmountParser.parse(trimmed),
              value.isFinite,
              value >= 0 else { return nil }
        return Int((value * Const.centsPerUnit).rounded())
    }

    /// The inverse of `cents(_:)` for display — locale-formatted to two
    /// places, matching how amounts are shown everywhere else.
    static func text(fromCents cents: Int) -> String {
        (Double(cents) / Const.centsPerUnit).asMoneyString
    }

    /// Whole cents for an amount Splitwise already gave us as a number (its
    /// `cost`/`paid_share`/`owed_share` strings, once parsed) — the same
    /// rounding the typed-input path above applies, so an untouched expense
    /// round-trips to exactly the values it arrived with.
    static func cents(fromAmount amount: Double) -> Int {
        Int((amount * Const.centsPerUnit).rounded())
    }

    /// Each value's fraction of their sum. Falls back to an even split when
    /// they sum to zero (or the list is all zeroes), since there's no ratio
    /// to preserve in that case and an even split is what "no information"
    /// should mean.
    static func ratios(of values: [Double]) -> [Double] {
        guard !values.isEmpty else { return [] }
        let total = values.reduce(0, +)
        guard total > 0 else { return evenRatios(count: values.count) }
        return values.map { $0 / total }
    }

    /// An equal fraction each — the split a changed total falls back on
    /// before anyone has adjusted a share by hand.
    static func evenRatios(count: Int) -> [Double] {
        guard count > 0 else { return [] }
        return Array(repeating: 1 / Double(count), count: count)
    }

    /// Splits `totalCents` in the given `ratios`, rounding each part to a
    /// whole cent and dropping whatever's left over from rounding onto the
    /// largest part — so the parts always add back up to `totalCents` exactly,
    /// which is what Splitwise validates. Putting the remainder on the largest
    /// part (rather than the first) keeps a lopsided split from having its
    /// smallest share nudged by a cent.
    static func distribute(totalCents: Int, ratios: [Double]) -> [Int] {
        guard !ratios.isEmpty else { return [] }
        var parts = ratios.map { Int((Double(totalCents) * $0).rounded()) }
        let leftover = totalCents - parts.reduce(0, +)
        if leftover != 0, let largest = parts.indices.max(by: { parts[$0] < parts[$1] }) {
            parts[largest] += leftover
        }
        return parts
    }
}
