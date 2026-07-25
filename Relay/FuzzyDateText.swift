//
//  FuzzyDateText.swift
//  Relay
//

import SwiftUI

/// Live-updating "time ago" label built on `Date.fuzzyBucketed(to:)`. Refreshes
/// exactly when the displayed string can change (the bucket boundaries) rather
/// than on a fixed interval — so a freshly-refreshed label doesn't invalidate
/// the view graph every second for a string that only changes three times in
/// the first minute, and a label left on screen for a long time stays idle.
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
    /// The timestamp being displayed — boundaries are paced by how long ago
    /// *this* was, not by when the schedule itself started running.
    let anchor: Date

    /// The next moment (strictly after `date`) at which `fuzzyBucketed`'s
    /// output can change: the near-term bucket edges (10s / 50s / 60s), then
    /// each whole minute, hour, and day measured from `anchor`. Ticking on
    /// these instead of a fixed interval means one refresh per visible change.
    private func nextBoundary(after date: Date) -> Date {
        let elapsed = date.timeIntervalSince(anchor)
        let boundary: TimeInterval
        switch elapsed {
        case ..<10: boundary = 10
        case ..<50: boundary = 50
        case ..<60: boundary = 60
        case ..<3600: boundary = (floor(elapsed / 60) + 1) * 60
        case ..<86400: boundary = (floor(elapsed / 3600) + 1) * 3600
        default: boundary = (floor(elapsed / 86400) + 1) * 86400
        }
        return anchor.addingTimeInterval(boundary)
    }

    func entries(from startDate: Date, mode: TimelineSchedule.Mode) -> AnyIterator<Date> {
        var next = startDate
        var emittedStart = false
        return AnyIterator {
            // Emit `startDate` itself first so the label renders immediately,
            // then step to each successive bucket boundary.
            if !emittedStart {
                emittedStart = true
                return startDate
            }
            next = nextBoundary(after: next)
            return next
        }
    }
}
