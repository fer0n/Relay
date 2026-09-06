//
//  SplitTarget.swift
//  Relay
//
//  Who an expense is split with: some or all of the people on one ledger.
//  A participant means nothing without the ledger they're on, hence the pair.
//

import Foundation

nonisolated struct SplitParticipant: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let firstName: String
    let fullName: String

    init(id: String, firstName: String, fullName: String) {
        self.id = id
        self.firstName = firstName
        self.fullName = fullName
    }

    init(_ participant: LedgerParticipant) {
        self.init(id: participant.id, firstName: participant.firstName, fullName: participant.displayName)
    }
}

/// The people a split bills, and the ledger it books them on.
nonisolated struct SplitTarget: Equatable, Sendable {
    /// Everyone but the signed-in user. Never empty for a usable target.
    let participants: [SplitParticipant]
    let zoneName: String
    /// Set only when the split is with *everyone* on the ledger — billing a
    /// subset is a split with those people, not with the ledger.
    let ledgerName: String?

    init(participants: [SplitParticipant], zoneName: String, ledgerName: String? = nil) {
        self.participants = participants
        self.zoneName = zoneName
        self.ledgerName = ledgerName
    }

    init(ledger: Ledger) {
        self.init(
            participants: ledger.others.map(SplitParticipant.init),
            zoneName: ledger.zoneName,
            ledgerName: ledger.name
        )
    }

    var displayName: String {
        if let ledgerName { return ledgerName }
        return ListFormatter.localizedString(byJoining: participants.map(\.firstName))
    }

    var isEmpty: Bool { participants.isEmpty }

    /// Nil for a whole-ledger or multi-person split. For the surfaces that
    /// store exactly one target, like a template's.
    var soleParticipant: SplitParticipant? {
        guard ledgerName == nil, participants.count == 1 else { return nil }
        return participants.first
    }

    /// Nil if the ledger went away between picking it and submitting.
    @MainActor
    var ledger: Ledger? {
        LedgerStore.shared.ledgers.first { $0.zoneName == zoneName }
    }
}
