//
//  LedgerParticipantUsageStore.swift
//  Relay
//
//  When each participant was last split with, so pickers surface recent
//  people first rather than CloudKit's own order.
//

import Foundation
import os

nonisolated struct LedgerParticipantUsage: Codable {
    var lastUsedByParticipantID: [String: Date] = [:]
}

nonisolated enum LedgerParticipantUsageStore {
    private static let fileURL = ApplicationSupportFile.url("ledger-participant-usage.json")
    /// `sorted` is read from a body, so the file is decoded once and held.
    private static let cached = OSAllocatedUnfairLock(initialState: LedgerParticipantUsage?.none)

    static func load() -> LedgerParticipantUsage {
        cached.withLock { state in
            if let state { return state }
            let data = try? Data(contentsOf: fileURL)
            let usage = data.flatMap { try? JSONDecoder().decode(LedgerParticipantUsage.self, from: $0) }
                ?? LedgerParticipantUsage()
            state = usage
            return usage
        }
    }

    static func recordUsage(participantIDs: [String]) {
        guard !participantIDs.isEmpty else { return }
        let now = Date()
        save { usage in
            for id in participantIDs { usage.lastUsedByParticipantID[id] = now }
        }
    }

    /// Keeps the later date, so an older backup can't demote someone still
    /// being split with.
    static func merge(_ incoming: LedgerParticipantUsage) {
        save { usage in
            for (id, date) in incoming.lastUsedByParticipantID {
                usage.lastUsedByParticipantID[id] = usage.lastUsedByParticipantID[id].map { max($0, date) } ?? date
            }
        }
    }

    private static func save(_ change: (inout LedgerParticipantUsage) -> Void) {
        var updated = load()
        change(&updated)
        let usage = updated
        cached.withLock { $0 = usage }
        guard let data = try? JSONEncoder().encode(usage) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    static func sorted(_ participants: [LedgerParticipant]) -> [LedgerParticipant] {
        UsageStore.sorted(participants, lastUsed: load().lastUsedByParticipantID, key: \.id)
    }
}
