//
//  SplitShareMath.swift
//  Relay
//
//  Whole-cent share arithmetic: shares must add up to the cost exactly, and
//  nothing server-side enforces that, so this and `LedgerExpense.isBalanced`
//  are all there is between a rounding slip and a balance that never settles.
//

import Foundation

nonisolated enum SplitShareMath {
    /// Either decimal separator. Nil for unparseable or negative — a share
    /// can be zero, never below it.
    static func cents(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let value = try? AmountParser.parse(trimmed),
              value.isFinite,
              value >= 0 else { return nil }
        return Int((value * Const.centsPerUnit).rounded())
    }

    /// The inverse of `cents(_:)`, for display.
    static func text(fromCents cents: Int) -> String {
        (Double(cents) / Const.centsPerUnit).asMoneyString
    }

    /// Same rounding as `cents(_:)`, so an untouched expense round-trips.
    static func cents(fromAmount amount: Double) -> Int {
        Int((amount * Const.centsPerUnit).rounded())
    }

    /// Each value's fraction of their sum, evenly when they sum to zero.
    static func ratios(of values: [Double]) -> [Double] {
        guard !values.isEmpty else { return [] }
        let total = values.reduce(0, +)
        guard total > 0 else { return evenRatios(count: values.count) }
        return values.map { $0 / total }
    }

    /// An equal fraction each.
    static func evenRatios(count: Int) -> [Double] {
        guard count > 0 else { return [] }
        return Array(repeating: 1 / Double(count), count: count)
    }

    /// Whole cents in the given ratios, always totalling `totalCents`. The
    /// rounding remainder lands on the largest part, so a lopsided split
    /// doesn't have its smallest share nudged.
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
