//
//  SplitTargetEntity.swift
//  Relay
//
//  A live Shortcuts picker of the ledgers and the people on them. One type
//  for both, told apart by `participantID`, so "Split With" stays one field.
//

import AppIntents
import Foundation

nonisolated struct SplitTargetEntity: AppEntity {
    let zoneName: String
    /// nil means everyone on the ledger.
    let participantID: String?
    let firstName: String
    /// `displayRepresentation` only, so people sharing a first name stay
    /// distinguishable. Prompts and dialogs use `firstName`.
    let fullName: String

    init(zoneName: String, participantID: String? = nil, firstName: String, fullName: String) {
        self.zoneName = zoneName
        self.participantID = participantID
        self.firstName = firstName
        self.fullName = fullName
    }

    init(ledger: Ledger) {
        self.init(zoneName: ledger.zoneName, firstName: ledger.name, fullName: ledger.name)
    }

    /// Qualified with the ledger's name, or a picker listing two shows the
    /// same person twice.
    init(ledger: Ledger, participant: LedgerParticipant) {
        self.init(
            zoneName: ledger.zoneName,
            participantID: participant.id,
            firstName: participant.firstName,
            fullName: "\(participant.displayName) (\(ledger.name))"
        )
    }

    /// Shortcuts stores this. "|" can't collide: Relay mints the zone names
    /// and CloudKit record names are alphanumeric with underscores.
    var id: String {
        guard let participantID else { return zoneName }
        return "\(zoneName)|\(participantID)"
    }

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Ledger or Person"
    static let defaultQuery = SplitTargetQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(fullName)")
    }
}

extension SplitTargetEntity {
    var cachedTarget: WalletTransactionConfig.CachedSplitTarget {
        WalletTransactionConfig.CachedSplitTarget(
            zoneName: zoneName,
            participantID: participantID,
            firstName: firstName,
            fullName: fullName
        )
    }

    init(cachedTarget: WalletTransactionConfig.CachedSplitTarget) {
        self.init(
            zoneName: cachedTarget.zoneName,
            participantID: cachedTarget.participantID,
            firstName: cachedTarget.firstName,
            fullName: cachedTarget.fullName
        )
    }
}

nonisolated struct SplitTargetQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [SplitTargetEntity] {
        await allTargets().filter { identifiers.contains($0.id) }
    }

    @MainActor
    func suggestedEntities() async throws -> [SplitTargetEntity] {
        await allTargets()
    }

    /// Never throws: Shortcuts resolves this just to render a configuration
    /// sheet. A missing iCloud account surfaces from `perform()` instead.
    @MainActor
    private func allTargets() async -> [SplitTargetEntity] {
        let store = LedgerStore.shared
        await store.refresh(force: false)
        guard store.isAvailable else { return [] }
        return store.ledgers.flatMap { ledger -> [SplitTargetEntity] in
            guard ledger.isShared else { return [] }
            return [SplitTargetEntity(ledger: ledger)]
                + LedgerParticipantUsageStore.sorted(ledger.others).map {
                    SplitTargetEntity(ledger: ledger, participant: $0)
                }
        }
    }
}
