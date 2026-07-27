//
//  SplitwiseNotification.swift
//  Relay
//
//  Codable models for `get_notifications` (https://dev.splitwise.com) — the
//  same recent-activity feed the Splitwise app shows under "Activity". Backs
//  SplitwiseActivityView.
//
//  Splitwise renders each entry itself and hands back a ready-made `content`
//  string rather than structured fields, so the feed is display-only: there's
//  nothing here to recompute an amount or a name from. The one thing Relay
//  acts on is a deleted expense, which `restorableExpenseId` picks out of
//  `type` + `source` so the row can offer "Restore".
//

import Foundation

nonisolated struct SplitwiseNotification: Codable, Identifiable {
    let id: Int
    /// Kept as the raw Int rather than decoded straight into
    /// `SplitwiseNotificationKind`: Splitwise documents the type list as
    /// incomplete and says values may be added without warning, so a
    /// non-failable Int keeps a future type from failing the whole response's
    /// decode. `kind` resolves it where a name is actually needed.
    let type: Int
    let createdAt: Date
    /// HTML, limited by Splitwise to `<strong>`, `<strike>`, `<small>`,
    /// `<br>` and `<font color="…">` — parsed for display by
    /// `SplitwiseNotificationContent`.
    let content: String
    /// What the entry is about (an `"Expense"`, `"Group"`, …). Optional so an
    /// entry Splitwise sends without one still decodes.
    let source: Source?

    struct Source: Codable {
        let type: String?
        let id: Int?
    }

    var kind: SplitwiseNotificationKind? { SplitwiseNotificationKind(rawValue: type) }

    /// The expense this entry refers to, or nil when it's about something
    /// else (a group, a friendship) — `source.id` alone isn't enough, since
    /// it's a different id space per source type.
    var expenseId: Int? {
        guard source?.type == "Expense" else { return nil }
        return source?.id
    }

    /// The expense id `undelete_expense` can bring back, i.e. non-nil only
    /// for an "expense deleted" entry that actually names an expense. Note a
    /// *later* restore of the same expense doesn't clear this — Splitwise
    /// leaves the original "deleted" entry in the feed — so callers pair it
    /// with `alreadyRestored(_:)` below rather than using it alone.
    var restorableExpenseId: Int? {
        guard kind == .expenseDeleted else { return nil }
        return expenseId
    }
}

/// The documented `type` values (https://dev.splitwise.com). Splitwise notes
/// this list is incomplete and may grow, which is why
/// `SplitwiseNotification.type` stays an Int and this is only consulted
/// through the failable `kind` — an unrecognized type still shows in the feed,
/// just with the generic icon.
nonisolated enum SplitwiseNotificationKind: Int {
    case expenseAdded = 0
    case expenseUpdated = 1
    case expenseDeleted = 2
    case commentAdded = 3
    case addedToGroup = 4
    case removedFromGroup = 5
    case groupDeleted = 6
    case groupSettingsChanged = 7
    case addedAsFriend = 8
    case removedAsFriend = 9
    case news = 10
    case debtSimplification = 11
    case groupUndeleted = 12
    case expenseUndeleted = 13
    case groupCurrencyConversion = 14
    case friendCurrencyConversion = 15

    /// Stands in for the icon Splitwise ships with each notification
    /// (`image_url`), which Relay deliberately doesn't fetch — a remote image
    /// per row would break the feed offline and doesn't match how the rest of
    /// the app draws list rows (accent-tinted SF Symbol, see `RowLabel`).
    var systemImage: String {
        switch self {
        case .expenseAdded: "plus.circle"
        case .expenseUpdated: "pencil"
        case .expenseDeleted: "trash"
        case .expenseUndeleted: "arrow.uturn.backward"
        case .commentAdded: "text.bubble"
        case .addedToGroup, .removedFromGroup, .groupDeleted, .groupSettingsChanged, .groupUndeleted: "person.3"
        case .addedAsFriend, .removedAsFriend: "person"
        case .news: "megaphone"
        case .debtSimplification: "arrow.left.arrow.right"
        case .groupCurrencyConversion, .friendCurrencyConversion: "arrow.2.squarepath"
        }
    }
}

nonisolated struct SplitwiseNotificationsResponse: Codable {
    let notifications: [SplitwiseNotification]
}

nonisolated extension Array where Element == SplitwiseNotification {
    /// When each expense was most recently brought back, keyed by expense id.
    /// Splitwise keeps the original "expense deleted" entry in the feed after
    /// a restore and adds a separate "expense undeleted" one, so this is what
    /// tells a delete entry apart from one that's already been undone.
    var latestRestoreDates: [Int: Date] {
        reduce(into: [:]) { result, notification in
            guard notification.kind == .expenseUndeleted, let expenseId = notification.expenseId else { return }
            if let existing = result[expenseId], existing >= notification.createdAt { return }
            result[expenseId] = notification.createdAt
        }
    }
}
