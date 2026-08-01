//
//  SplitwiseNotification.swift
//  Relay
//
//  Codable models for `get_notifications` (https://dev.splitwise.com) — the
//  activity feed behind SplitwiseActivityView.
//
//  Splitwise hands back a ready-made `content` string rather than structured
//  fields, so the feed is display-only. The one thing Relay acts on is a deleted
//  expense, which `restorableExpenseId` picks out so the row can offer "Restore".
//

import Foundation

nonisolated struct SplitwiseNotification: Codable, Identifiable {
    let id: Int
    /// A raw Int rather than a `SplitwiseNotificationKind`: Splitwise documents the
    /// type list as incomplete, so this keeps a future value from failing the whole
    /// response's decode. `kind` resolves it where a name is needed.
    let type: Int
    let createdAt: Date
    /// HTML, limited by Splitwise to a documented handful of tags — parsed for
    /// display by `SplitwiseNotificationContent`.
    let content: String
    /// Optional so an entry Splitwise sends without one still decodes.
    let source: Source?

    struct Source: Codable {
        let type: String?
        let id: Int?
    }

    var kind: SplitwiseNotificationKind? { SplitwiseNotificationKind(rawValue: type) }

    /// nil when the entry is about something else — `source.id` alone isn't enough,
    /// being a different id space per source type.
    var expenseId: Int? {
        guard source?.type == "Expense" else { return nil }
        return source?.id
    }

    /// Non-nil only for an "expense deleted" entry that names an expense. A later
    /// restore doesn't clear it — Splitwise leaves the original "deleted" entry in
    /// the feed — so callers pair it with `alreadyRestored(_:)` below.
    var restorableExpenseId: Int? {
        guard kind == .expenseDeleted else { return nil }
        return expenseId
    }
}

/// The documented `type` values. Splitwise notes the list is incomplete, which is
/// why `SplitwiseNotification.type` stays an Int and this is only reached through
/// the failable `kind` — an unrecognized type still shows, with a generic icon.
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

    /// Stands in for Splitwise's own `image_url`, which Relay doesn't fetch: a
    /// remote image per row would break the feed offline and wouldn't match how the
    /// rest of the app draws list rows.
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
    /// When each expense was most recently restored. Splitwise keeps the original
    /// "deleted" entry in the feed and adds a separate "undeleted" one, so this is
    /// what tells a delete entry apart from one already undone.
    var latestRestoreDates: [Int: Date] {
        reduce(into: [:]) { result, notification in
            guard notification.kind == .expenseUndeleted, let expenseId = notification.expenseId else { return }
            if let existing = result[expenseId], existing >= notification.createdAt { return }
            result[expenseId] = notification.createdAt
        }
    }
}
