//
//  FuzzyDateText.swift
//  Relay
//

import SwiftUI

/// Live-updating "time ago" label built on `Date.fuzzyBucketed(to:)`. Ticks
/// every second while the near-term buckets ("now", "less than 30s ago", …)
/// are in play, then backs off to a coarser interval once
/// RelativeDateTimeFormatter's minute/hour/day granularity takes over — so a
/// label left on screen for a long time (e.g. an open detail sheet) doesn't
/// keep invalidating the view graph every second.
struct FuzzyDateText: View {
    let date: Date

    var body: some View {
        TimelineView(FuzzyDateSchedule(anchor: date)) { context in
            let text = date.fuzzyBucketed(to: context.date)
            Text(text)
                .contentTransition(.numericText())
                .animation(.default, value: text)
        }
    }
}

private struct FuzzyDateSchedule: TimelineSchedule {
    /// The timestamp being displayed — ticks are paced by how long ago
    /// *this* was, not by when the schedule itself started running.
    let anchor: Date

    func entries(from startDate: Date, mode: TimelineSchedule.Mode) -> AnyIterator<Date> {
        var next = startDate
        return AnyIterator {
            let date = next
            let elapsed = date.timeIntervalSince(anchor)
            let interval: TimeInterval = elapsed < 60 ? 1 : (elapsed < 3600 ? 30 : 60)
            next = next.addingTimeInterval(interval)
            return date
        }
    }
}
