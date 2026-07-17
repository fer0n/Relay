//
//  Formatting.swift
//  Hazel
//

import Foundation

extension Double {
    /// Fixed two-decimal-place formatting used throughout transaction/expense amount display.
    nonisolated var asMoneyString: String {
        formatted(.number.precision(.fractionLength(2)))
    }
}

extension DateFormatter {
    /// "yyyy-MM-dd" in the current time zone — used for YNAB/Splitwise import IDs and API date strings.
    nonisolated static let yyyyMMdd: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter
    }()
}
