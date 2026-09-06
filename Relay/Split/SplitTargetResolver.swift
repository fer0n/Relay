//
//  SplitTargetResolver.swift
//  Relay
//
//  A picked `SplitTargetEntity` into the people it bills; a whole ledger
//  carries only its name, so membership is looked up first.
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
            throw LedgerExpenseError.validation(String(localized: "Couldn't find that ledger."))
        }

        guard let participantID = entity.participantID else {
            let target = SplitTarget(ledger: ledger)
            guard !target.isEmpty else {
                throw LedgerExpenseError.validation(String(localized: "Nobody else is on that ledger yet."))
            }
            return target
        }
        guard let participant = ledger.participant(id: participantID), !participant.isCurrentUser else {
            throw LedgerExpenseError.validation(String(localized: "That person isn't on the ledger any more."))
        }
        return SplitTarget(
            participants: [SplitParticipant(participant)],
            zoneName: ledger.zoneName
        )
    }
}
