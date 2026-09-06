//
//  LedgerModels.swift
//  Relay
//
//  A shared expense list, one CloudKit zone each. A participant *is* a
//  CKShare participant, identified by `CKContainer.userRecordID()` — never
//  by the share; see `LedgerRecords.currentUserPlaceholder`.
//

import CloudKit
import Foundation

/// One person on a ledger's CloudKit share.
nonisolated struct LedgerParticipant: Identifiable, Equatable, Hashable, Codable, Sendable {
    /// CloudKit user record name: stable per iCloud account in this container.
    let id: String
    /// Nil asymmetrically — CloudKit reveals a name only to viewers that
    /// person is discoverable to. A privacy rule, not an error.
    let name: String?
    let isCurrentUser: Bool
    let hasAccepted: Bool
    /// Only the owner may delete the ledger or manage who's on it.
    let isOwner: Bool
    let imageData: Data?
    /// `name` came from a profile, not CloudKit.
    let hasProfile: Bool

    init(
        id: String,
        name: String?,
        isCurrentUser: Bool,
        hasAccepted: Bool,
        isOwner: Bool,
        imageData: Data? = nil,
        hasProfile: Bool = false
    ) {
        self.id = id
        self.name = name
        self.isCurrentUser = isCurrentUser
        self.hasAccepted = hasAccepted
        self.isOwner = isOwner
        self.imageData = imageData
        self.hasProfile = hasProfile
    }

    /// A profile name beats CloudKit's: everybody on the ledger sees it.
    func applying(_ profile: LedgerProfile?) -> LedgerParticipant {
        guard let profile else { return self }
        return LedgerParticipant(
            id: id,
            name: profile.displayName ?? name,
            isCurrentUser: isCurrentUser,
            hasAccepted: hasAccepted,
            isOwner: isOwner,
            imageData: profile.imageData ?? imageData,
            hasProfile: profile.displayName != nil
        )
    }

    var initials: String {
        let source = name ?? (isCurrentUser ? String(localized: "You") : displayName)
        let letters = source.split(separator: " ").prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    /// Joined but unnamed is "Someone", never "Invited".
    var displayName: String {
        if isCurrentUser { return String(localized: "You") }
        if let name { return name }
        return hasAccepted ? Self.unknownName : Self.invitedName
    }

    var firstName: String {
        guard let name else { return displayName }
        return name.split(separator: " ").first.map(String.init) ?? name
    }

    var shortName: String {
        isCurrentUser ? String(localized: "You") : firstName
    }

    static let invitedName = String(localized: "Invited")
    static let unknownName = String(localized: "Someone")
}

/// Who fronted the money and who owes for it, independently.
nonisolated struct LedgerExpenseShare: Equatable, Hashable, Codable, Sendable {
    let participantID: String
    let paidCents: Int
    let owedCents: Int

    init(participantID: String, paidCents: Int, owedCents: Int) {
        self.participantID = participantID
        self.paidCents = paidCents
        self.owedCents = owedCents
    }
}

/// A single expense on a ledger, one CloudKit record in the ledger's zone.
nonisolated struct LedgerExpense: Identifiable, Equatable, Codable, Sendable {
    /// The CKRecord's name.
    let id: String
    var title: String
    var costCents: Int
    var currencyCode: String
    var date: Date
    /// Order carries no meaning — `payers` and `debtors` resolve by amount.
    var shares: [LedgerExpenseShare]
    /// Structurally an ordinary expense; only the wording differs.
    var isSettlement: Bool
    /// Nil only before the expense is written.
    let createdBy: String?
    let createdAt: Date

    init(
        id: String = UUID().uuidString,
        title: String,
        costCents: Int,
        currencyCode: String,
        date: Date,
        shares: [LedgerExpenseShare],
        isSettlement: Bool = false,
        createdBy: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.costCents = costCents
        self.currencyCode = currencyCode
        self.date = date
        self.shares = shares
        self.isSettlement = isSettlement
        self.createdBy = createdBy
        self.createdAt = createdAt
    }

    /// A one-payer expense the recipient owes in full.
    static func settlement(
        from payerID: String,
        to recipientID: String,
        cents: Int,
        currencyCode: String,
        date: Date = Date()
    ) -> LedgerExpense {
        LedgerExpense(
            title: "Payment",
            costCents: cents,
            currencyCode: currencyCode,
            date: date,
            shares: [
                LedgerExpenseShare(participantID: payerID, paidCents: cents, owedCents: 0),
                LedgerExpenseShare(participantID: recipientID, paidCents: 0, owedCents: cents),
            ],
            isSettlement: true
        )
    }

    var payers: [LedgerExpenseShare] { shares.filter { $0.paidCents > 0 } }

    /// The denominator every pairwise figure is a fraction of.
    var totalPaidCents: Int { shares.reduce(0) { $0 + $1.paidCents } }

    var debtors: [LedgerExpenseShare] { shares.filter { $0.owedCents > 0 } }

    func share(for participantID: String) -> LedgerExpenseShare? {
        shares.first { $0.participantID == participantID }
    }

    func netCents(for participantID: String) -> Int {
        guard let share = share(for: participantID) else { return 0 }
        return share.paidCents - share.owedCents
    }

    /// Nothing server-side enforces this, so it runs before every write.
    var isBalanced: Bool {
        costCents >= 0
            && totalPaidCents == costCents
            && shares.reduce(0) { $0 + $1.owedCents } == costCents
    }
}

/// One CloudKit zone, shared as a unit so any participant can add expenses.
nonisolated struct Ledger: Identifiable, Equatable, Sendable {
    let zoneID: CKRecordZone.ID
    var name: String
    /// Per ledger: a list mixing currencies has no single balance.
    var currencyCode: String
    let createdAt: Date
    /// False for a ledger reached through the shared database.
    let isOwnedByCurrentUser: Bool
    /// Empty until shared. A solo ledger is a valid state.
    var participants: [LedgerParticipant]
    /// Report each pair what the settle-up plan says rather than what they ran
    /// up, collapsing debts routed through a third person. A ledger property,
    /// not a device one.
    var simplifiesDebts: Bool = true

    /// So views and routes key off it without importing CloudKit.
    var zoneName: String { zoneID.zoneName }

    var id: String { zoneName }

    var currentUser: LedgerParticipant? {
        participants.first { $0.isCurrentUser }
    }

    /// Nil until participants load; that's the only reason both exist.
    var currentUserID: String? { currentUser?.id }

    /// Everyone billable. Pending invitees can't see the ledger, so billing
    /// them creates a balance nobody can settle.
    var others: [LedgerParticipant] {
        participants.filter { !$0.isCurrentUser && $0.hasAccepted }
    }

    var pendingInvites: [LedgerParticipant] {
        participants.filter { !$0.isCurrentUser && !$0.hasAccepted }
    }

    func participant(id: String) -> LedgerParticipant? {
        participants.first { $0.id == id }
    }

    /// Applied by the store: profiles arrive a zone walk later than participants.
    func applyingProfiles(_ profiles: [String: LedgerProfile]) -> Ledger {
        guard !profiles.isEmpty else { return self }
        var copy = self
        copy.participants = participants.map { $0.applying(profiles[$0.id]) }
        return copy
    }

    var participantsSummary: String {
        ListFormatter.localizedString(byJoining: others.map(\.firstName))
    }

    var isShared: Bool { !others.isEmpty }
}
