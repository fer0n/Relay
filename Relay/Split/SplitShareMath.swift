//
//  SplitShareMath.swift
//  Relay
//
//  Whole-cent share arithmetic. Nothing server-side enforces that shares add
//  up, so this and `LedgerExpense.isBalanced` are all there is.
//

import Foundation

nonisolated enum SplitShareMath {
    /// Either decimal separator. Nil for unparseable or negative.
    static func cents(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let value = try? AmountParser.parse(trimmed),
              value.isFinite,
              value >= 0 else { return nil }
        return cents(fromAmount: value)
    }

    static func text(fromCents cents: Int) -> String {
        cents.asMoneyString
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

    static func evenRatios(count: Int) -> [Double] {
        guard count > 0 else { return [] }
        return Array(repeating: 1 / Double(count), count: count)
    }

    /// Always totals `totalCents`; the remainder lands on the largest part,
    /// so a lopsided split doesn't have its smallest share nudged.
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
