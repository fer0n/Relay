//
//  LedgerModels.swift
//  Relay
//
//  A ledger is Relay's own shared expense list, one CloudKit zone each.
//
//  Identity is CloudKit's: a participant *is* a CKShare participant, so
//  there's no invite/friend model — accepting the share is the invite. Their
//  id comes from `CKContainer.userRecordID()`, never from the share; see
//  `LedgerRecords.currentUserPlaceholder` for why.
//

import CloudKit
import Foundation

/// One person on a ledger's CloudKit share.
nonisolated struct LedgerParticipant: Identifiable, Equatable, Hashable, Codable, Sendable {
    /// The participant's CloudKit user record name — stable per iCloud
    /// account within this container, on every device.
    let id: String
    /// Nil far more often than you'd expect, and asymmetrically: CloudKit only
    /// reveals a name to a viewer that person is discoverable to. A privacy
    /// rule, not an error, and never "hasn't accepted".
    let name: String?
    let isCurrentUser: Bool
    let hasAccepted: Bool
    /// Only the owner may delete the ledger or manage who's on it.
    let isOwner: Bool
    let imageData: Data?
    /// True when `name` was typed into a profile rather than supplied by
    /// CloudKit — how the members screen tells "not set yet" apart.
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

    /// A profile name beats CloudKit's: it's the one everybody on the ledger
    /// sees.
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

    /// Someone who's joined but whose name CloudKit won't reveal is
    /// "Someone", never "Invited" — they can see the ledger.
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

/// One person's stake in an expense. Both sides are stored per participant:
/// who fronted the money and who owes for it are independent.
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
    /// The CKRecord's name, a UUID minted on creation.
    let id: String
    var title: String
    var costCents: Int
    var currencyCode: String
    var date: Date
    /// Order carries no meaning — `payers` and `debtors` resolve by amount.
    var shares: [LedgerExpenseShare]
    /// Structurally an ordinary expense; only the wording differs, so the
    /// list can say "Alex paid you €20".
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

    /// A one-payer expense the recipient owes in full, which is why settling
    /// needs no separate record type.
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

    /// What the payers fronted between them — the denominator every
    /// pairwise figure is a fraction of.
    var totalPaidCents: Int { shares.reduce(0) { $0 + $1.paidCents } }

    var debtors: [LedgerExpenseShare] { shares.filter { $0.owedCents > 0 } }

    func share(for participantID: String) -> LedgerExpenseShare? {
        shares.first { $0.participantID == participantID }
    }

    /// What they fronted, less what they owe.
    func netCents(for participantID: String) -> Int {
        guard let share = share(for: participantID) else { return 0 }
        return share.paidCents - share.owedCents
    }

    /// Nothing server-side enforces that the shares total, so this runs
    /// before every write.
    var isBalanced: Bool {
        costCents >= 0
            && totalPaidCents == costCents
            && shares.reduce(0) { $0 + $1.owedCents } == costCents
    }
}

/// One CloudKit record zone, shareable as a unit: a zone-wide `CKShare`
/// covers every expense in it, so any participant can add their own.
nonisolated struct Ledger: Identifiable, Equatable, Sendable {
    let zoneID: CKRecordZone.ID
    var name: String
    /// Per ledger, not per expense: a list mixing currencies has no single
    /// balance.
    var currencyCode: String
    let createdAt: Date
    /// False for a ledger reached through the shared database.
    let isOwnedByCurrentUser: Bool
    /// Empty until shared. A solo ledger is a valid state, not a half-built
    /// one.
    var participants: [LedgerParticipant]
    /// Shows each pair what the settle-up plan says they owe rather than what
    /// they ran up between them, so a debt routed through a third person
    /// becomes one direct debt. On by default, and shared: it's a property of
    /// the ledger, not of the device reading it.
    var simplifiesDebts: Bool = true

    /// The ledger's identity, as a plain `String` so views and routes can key
    /// off it without importing CloudKit.
    var zoneName: String { zoneID.zoneName }

    var id: String { zoneName }

    var currentUser: LedgerParticipant? {
        participants.first { $0.isCurrentUser }
    }

    /// Equal to `LedgerStore.currentUserID` once participants have loaded;
    /// nil before that, which is the only reason both exist.
    var currentUserID: String? { currentUser?.id }

    /// Everyone billable. Pending invitees are excluded: they can't see the
    /// ledger, so billing them creates a balance nobody can settle.
    var others: [LedgerParticipant] {
        participants.filter { !$0.isCurrentUser && $0.hasAccepted }
    }

    var pendingInvites: [LedgerParticipant] {
        participants.filter { !$0.isCurrentUser && !$0.hasAccepted }
    }

    func participant(id: String) -> LedgerParticipant? {
        participants.first { $0.id == id }
    }

    /// Applied by the store, not the service: profiles arrive with the
    /// expenses, a zone walk later than the participant list.
    func applyingProfiles(_ profiles: [String: LedgerProfile]) -> Ledger {
        guard !profiles.isEmpty else { return self }
        var copy = self
        copy.participants = participants.map { $0.applying(profiles[$0.id]) }
        return copy
    }

    var participantsSummary: String {
        ListFormatter.localizedString(byJoining: others.map(\.firstName))
    }

    /// Drives the "invite someone" empty state. A solo ledger can still hold
    /// expenses; they just all net to zero.
    var isShared: Bool { !others.isEmpty }
}
