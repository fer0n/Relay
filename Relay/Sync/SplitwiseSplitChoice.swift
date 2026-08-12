//
//  SplitwiseSplitChoice.swift
//  Relay
//
//  What the in-app draft/manual forms offer in their "Split" picker. A
//  superset of the Shortcuts-facing `SplitwiseSplitOption`: it adds
//  `.shares`, where the split is given as relative weights (1 : 2 …) and
//  the own share is worked out from them, the way
//  SplitwiseExpenseDetailView's "Shares" mode does.
//
//  `.shares` deliberately stays out of `SplitwiseSplitOption`, which is an
//  AppEnum: a Shortcuts run has nowhere to type weights, and a template
//  stores a fixed setting rather than per-transaction numbers. By the time
//  an expense is written the weights are already an amount, so `.shares`
//  submits as `.manual`.
//

import Foundation

nonisolated enum SplitwiseSplitChoice: String, Hashable, CaseIterable, Codable {
    case always
    case shares
    case manual
    case never

    /// Raw values match `SplitwiseSplitOption`'s for the three shared cases,
    /// so a choice persisted by either type reads back as the other.
    init(_ option: SplitwiseSplitOption) {
        switch option {
        case .always: self = .always
        case .manual: self = .manual
        case .never: self = .never
        }
    }

    /// What actually gets submitted — `.shares` resolves to `.manual`, with
    /// the own share coming from the weights instead of a typed field.
    var submitOption: SplitwiseSplitOption {
        switch self {
        case .always: .always
        case .shares, .manual: .manual
        case .never: .never
        }
    }

    var label: String {
        switch self {
        case .shares: String(localized: "Split by Shares")
        default: submitOption.label
        }
    }
}
