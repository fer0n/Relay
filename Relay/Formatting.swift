//
//  Formatting.swift
//  Relay
//

import Foundation

extension Double {
    /// Fixed two-decimal-place formatting used throughout transaction/expense amount display.
    nonisolated var asMoneyString: String {
        formatted(.number.precision(.fractionLength(2)))
    }
}

extension Date {
    /// Localized, single-unit "time ago" (e.g. "3 sec ago", "4 min ago",
    /// "2 hr ago", "1 day ago") for a live-updating label. RelativeDateTimeFormatter
    /// already shows just the largest whole unit, so it steps in stable
    /// increments rather than counting across two units the way Text's
    /// built-in `.relative` style does — and it handles pluralization and
    /// wording per the user's locale. Pair with `.monospacedDigit()` to keep
    /// the width from jumping. `now` is passed in (rather than read from the
    /// clock) so a TimelineView tick drives it deterministically.
    nonisolated func fuzzyRelative(to now: Date) -> String {
        // RelativeDateTimeFormatter isn't Sendable/thread-safe to share, and
        // it's only formatted from the main thread (SwiftUI body) once a
        // second per label, so a fresh instance per call is cheap and safe.
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.dateTimeStyle = .numeric
        return formatter.localizedString(for: self, relativeTo: now)
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
