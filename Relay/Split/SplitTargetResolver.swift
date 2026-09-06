//
//  SplitTargetResolver.swift
//  Relay
//
//  Turns a picked `SplitTargetEntity` into the people it bills. A whole
//  ledger only carries its name, so membership has to be looked up first.
//

import Foundation

@MainActor
enum SplitTargetResolver {
    static func resolve(_ entity: SplitTargetEntity) async throws -> SplitTarget {
        let store = LedgerStore.shared
        // A ledger picked months ago may not be loaded yet this launch.
        if !store.ledgers.contains(where: { $0.zoneName == entity.zoneName }) {
            await store.refresh(force: true)
        }
        guard let ledger = store.ledgers.first(where: { $0.zoneName == entity.zoneName }) else {
            throw LedgerExpenseError.validation("Couldn't find that ledger.")
        }

        guard let participantID = entity.participantID else {
            let target = SplitTarget(ledger: ledger)
            guard !target.isEmpty else {
                throw LedgerExpenseError.validation("Nobody else is on that ledger yet.")
            }
            return target
        }
        guard let participant = ledger.participant(id: participantID), !participant.isCurrentUser else {
            throw LedgerExpenseError.validation("That person isn't on the ledger any more.")
        }
        return SplitTarget(
            participants: [SplitParticipant(participant)],
            zoneName: ledger.zoneName
        )
    }
}
