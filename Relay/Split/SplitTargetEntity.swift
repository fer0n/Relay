//
//  SplitTargetEntity.swift
//  Relay
//
//  AppEntity/EntityQuery so Shortcuts can present a live picker of the
//  ledgers the user is on and the people on them. A whole ledger and one
//  person share this type — told apart by `participantID` — so the "Split
//  With" parameter offers either without growing a second field.
//

import AppIntents
import Foundation

nonisolated struct SplitTargetEntity: AppEntity {
    let zoneName: String
    /// nil means everyone on the ledger.
    let participantID: String?
    let firstName: String
    /// `displayRepresentation` only, so people sharing a first name stay
    /// distinguishable in a picker. Prompts and dialogs use `firstName`.
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

    /// Qualified with the ledger's name, so a picker listing two doesn't show
    /// the same person twice with no way to tell them apart.
    init(ledger: Ledger, participant: LedgerParticipant) {
        self.init(
            zoneName: ledger.zoneName,
            participantID: participant.id,
            firstName: participant.firstName,
            fullName: "\(participant.displayName) (\(ledger.name))"
        )
    }

    /// Shortcuts stores this, so it identifies a target on its own. "|" can't
    /// collide: Relay generates the zone names and CloudKit record names are
    /// alphanumeric with underscores.
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

    /// Each ledger, then the people on it.
    ///
    /// Never throws: Shortcuts resolves this just to render an action's
    /// configuration sheet, even for someone who doesn't split at all. A
    /// missing iCloud account surfaces from `perform()` instead.
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
