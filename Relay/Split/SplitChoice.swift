//
//  SplitChoice.swift
//  Relay
//
//  What the in-app forms offer in their "Split" picker: `SplitOption` plus
//  `.shares`, where the split is given as relative weights.
//
//  `.shares` stays out of `SplitOption`, an AppEnum: a Shortcuts run has
//  nowhere to type weights. By submit time they're already an amount, so it
//  goes through as `.manual`.
//

import Foundation

nonisolated enum SplitChoice: String, Hashable, CaseIterable, Codable {
    case always
    case shares
    case manual
    case never

    /// Raw values match `SplitOption`'s, so either persists as the other.
    init(_ option: SplitOption) {
        switch option {
        case .always: self = .always
        case .manual: self = .manual
        case .never: self = .never
        }
    }

    /// `.shares` resolves to `.manual`, its own share from the weights.
    var submitOption: SplitOption {
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
