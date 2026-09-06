//
//  DefaultSplitTargetStore.swift
//  Relay
//
//  The app-wide "who do I usually split with", for when nothing more specific
//  said. Stores a `CachedSplitTarget`, so the default, a template's remembered
//  target and a draft's pending one are all the same value.
//

import Foundation
import os

nonisolated enum DefaultSplitTargetStore {
    private static let fileURL = ApplicationSupportFile.url("default-split-target.json")

    /// `load()` sits on ContentView's body path — the pinned balance card is
    /// resolved through it — so the file is decoded once and held rather than
    /// re-read on every invalidation. Same reasoning, and same shape, as
    /// `LedgerParticipantUsageStore`; every write below refreshes it, and
    /// nothing else touches the file.
    private static let cached = OSAllocatedUnfairLock(
        initialState: WalletTransactionConfig.CachedSplitTarget??.none
    )

    static func load() -> WalletTransactionConfig.CachedSplitTarget? {
        cached.withLock { state in
            if let state { return state }
            let data = try? Data(contentsOf: fileURL)
            let target = data.flatMap { try? JSONDecoder().decode(StoredTarget.self, from: $0).asCachedTarget }
            state = .some(target)
            return target
        }
    }

    static func save(_ target: WalletTransactionConfig.CachedSplitTarget) throws {
        let data = try JSONEncoder().encode(StoredTarget(target))
        try data.write(to: fileURL, options: .atomic)
        cached.withLock { $0 = .some(target) }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
        cached.withLock { $0 = .some(nil) }
    }

    /// A mirror rather than making `CachedSplitTarget` Codable: that type is
    /// passed between pickers, and a serialised form would make every field a
    /// storage decision.
    private struct StoredTarget: Codable {
        let zoneName: String
        let participantID: String?
        let firstName: String
        let fullName: String

        init(_ target: WalletTransactionConfig.CachedSplitTarget) {
            zoneName = target.zoneName
            participantID = target.participantID
            firstName = target.firstName
            fullName = target.fullName
        }

        var asCachedTarget: WalletTransactionConfig.CachedSplitTarget {
            WalletTransactionConfig.CachedSplitTarget(
                zoneName: zoneName,
                participantID: participantID,
                firstName: firstName,
                fullName: fullName
            )
        }
    }
}
