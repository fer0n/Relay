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
    static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.dateTimeStyle = .numeric
        return formatter
    }()
    
    /// Localized, single-unit "time ago" (e.g. "3 sec ago", "4 min ago",
    /// "2 hr ago", "1 day ago") for a live-updating label. RelativeDateTimeFormatter
    /// already shows just the largest whole unit, so it steps in stable
    /// increments rather than counting across two units the way Text's
    /// built-in `.relative` style does — and it handles pluralization and
    /// wording per the user's locale. Pair with `.monospacedDigit()` to keep
    /// the width from jumping. `now` is passed in (rather than read from the
    /// clock) so a TimelineView tick drives it deterministically.
    func fuzzyRelative(to now: Date) -> String {
        // RelativeDateTimeFormatter isn't Sendable/thread-safe to share, and
        // it's only formatted from the main thread (SwiftUI body) once a
        // second per label, so a fresh instance per call is cheap and safe.
        return Date.relativeFormatter.localizedString(for: self, relativeTo: now)
    }

    /// Coarser near-term phrasing ("now", "less than 30s ago", "less than a
    /// minute ago") in place of RelativeDateTimeFormatter's "0 sec ago"/"3
    /// sec ago", which reads as falsely precise for a poll-driven refresh
    /// timestamp. Falls through to `fuzzyRelative(to:)` once a minute has
    /// passed. Use via `FuzzyDateText` for a live-updating label.
    func fuzzyBucketed(to now: Date) -> String {
        let seconds = now.timeIntervalSince(self)
        switch seconds {
        case ..<10:
            return String(localized: "Now")
        case ..<50:
            return String(localized: "30s ago")
        case ..<60:
            return String(localized: "1 min ago")
        default:
            return fuzzyRelative(to: now)
        }
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
