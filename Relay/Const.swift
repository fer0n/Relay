//
//  Const.swift
//  Relay
//
//  One home for literals that have to agree across files.
//
//  Deliberately *not* here: literals that only appear at one call site, the
//  on-disk store filenames (each owned by its store), and OAuth
//  endpoints/client IDs (see `OAuthConfig`). `AppShortcut.systemImageName` in
//  `RelayShortcuts` also has to stay inline — AppIntents reads it statically and
//  rejects anything but a literal.
//

nonisolated struct Const {
    /// Also has to match the `UIApplicationShortcutItemType` prefix in
    /// Info.plist, and must stay stable — changing it orphans every stored token.
    static let bundleID = "com.octabits.relay"

    static let loggerSubsystem = bundleID
    static let keychainService = bundleID

    /// Fallback currency for amounts Relay creates itself — Splitwise requires an
    /// explicit code on `create_expense`, and statement rows carry no currency.
    static let currencyCode = "EUR"

    /// YNAB amounts are milliunits, with outflows negative.
    static let milliunitsPerUnit: Double = 1000

    /// Splitwise amounts are in minor units.
    static let centsPerUnit: Double = 100

    /// SF Symbols shown on more than one screen, so the same thing always draws
    /// the same way. Named for the *job* the icon does, not the glyph, which is
    /// what changes when the design does. A symbol whose call sites don't share
    /// one job stays an inline literal at each site instead.
    struct Symbol {
        /// A transaction's free-text title — YNAB payee, Splitwise description,
        /// statement memo. See `TransactionService.titleFieldLabel`.
        static let titleField = "text.alignleft"
        /// Where the money came from: a YNAB account, a card, an expense's payer.
        static let account = "creditcard.fill"
        static let category = "tag.fill"
        static let template = "doc.on.doc"
        /// The people a transaction is split with.
        static let friends = "person.2.fill"
        /// One participant: a friend with no avatar, a single person's share.
        static let person = "person.fill"
        /// The Splitwise activity feed.
        static let activity = "bell.fill"
        /// Operations waiting to reach YNAB/Splitwise.
        static let pending = "arrow.triangle.2.circlepath"
        static let fileImport = "doc.badge.plus"
        static let drafts = "square.and.pencil"
        static let delete = "trash.fill"
        static let add = "plus"
        /// An affirmative state: exported, selected, checklist step completed.
        static let checkmark = "checkmark"
        /// The not-yet counterpart to `checkmark`.
        static let unchecked = "circle"
        static let dismissKeyboard = "chevron.down"
        /// A run dropped as a duplicate — see `TransactionClaim`.
        static let duplicateSkipped = "link"
        /// A pending operation that failed and is being retried.
        static let syncError = "exclamationmark.triangle.fill"
    }

    struct HTTP {
        static let post = "POST"
        static let authorizationHeader = "Authorization"
        static let contentTypeHeader = "Content-Type"
        static let retryAfterHeader = "Retry-After"
        static let jsonContentType = "application/json"

        /// Only ever passed to YNAB's/Splitwise's own API and never logged, per
        /// the token-handling rules in CLAUDE.md.
        static func bearer(_ token: String) -> String { "Bearer \(token)" }
    }

    /// Documented values for YNAB's `cleared` transaction field.
    struct YNAB {
        static let cleared = "cleared"
        static let uncleared = "uncleared"
    }
}
