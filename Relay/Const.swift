//
//  Const.swift
//  Relay
//
//  One home for literals that have to agree across files — SF Symbol names
//  reused by several screens, the HTTP plumbing both API clients spell out,
//  the unit conversions YNAB/Splitwise amounts go through, and the bundle
//  identifier that doubles as the log subsystem and Keychain service.
//
//  Deliberately *not* here: literals that only ever appear at one call site
//  (they read better inline), the on-disk store filenames (each already owned
//  by its store), and OAuth endpoints/client IDs (see `OAuthConfig`). One
//  repeated string also has to stay inline because the tooling reads it
//  statically: `AppShortcut.systemImageName` in `RelayShortcuts`, which
//  AppIntents rejects unless it's a literal.
//

nonisolated struct Const {
    /// The app's bundle identifier. Kept as the single spelling because it
    /// also has to match the `UIApplicationShortcutItemType` prefix in
    /// Info.plist, and because the Keychain service name derived from it must
    /// stay stable — changing it orphans every stored token.
    static let bundleID = "com.octabits.relay"

    /// `os.log` subsystem for every `Logger` in the app; conventionally the
    /// bundle identifier, so log output groups under the app in Console.
    static let loggerSubsystem = bundleID

    /// Keychain service under which the YNAB/Splitwise OAuth tokens are
    /// stored (see `KeychainStore`).
    static let keychainService = bundleID

    /// Fallback currency for amounts Relay creates itself — Splitwise
    /// requires an explicit currency code on `create_expense`, and imported
    /// statement rows carry an amount but no currency.
    static let currencyCode = "EUR"

    /// YNAB expresses transaction amounts in milliunits: 1000 milliunits is
    /// one currency unit, and outflows are negative.
    static let milliunitsPerUnit: Double = 1000

    /// Splitwise expresses expense amounts in minor units (cents).
    static let centsPerUnit: Double = 100

    /// SF Symbol names shown on more than one screen, so the same thing always
    /// draws the same way (a category always carries the tag icon, an account
    /// always the card icon, and so on).
    ///
    /// Named for the *job* the icon does, not the glyph — the glyph is what
    /// changes when the design does, and a name like `warning` stops being
    /// true the moment the icon moves. A symbol whose call sites don't share
    /// one job doesn't belong here: it stays an inline literal at each site
    /// (`TransactionService.systemImage`'s per-service icons,
    /// `SplitwiseNotification.Kind.systemImage`'s activity-feed table).
    struct Symbol {
        /// A transaction's free-text title field — YNAB payee, Splitwise
        /// description, statement memo. See `TransactionService.titleFieldLabel`.
        static let titleField = "text.alignleft"
        /// Where the money came from: a YNAB account, a mapped card, the payer
        /// of a Splitwise expense.
        static let account = "creditcard.fill"
        static let category = "tag.fill"
        static let template = "doc.on.doc"
        /// The people a transaction is split with — the balances list, a
        /// split's "With" row.
        static let friends = "person.2.fill"
        /// One participant: a friend with no avatar, a single person's share.
        static let person = "person.fill"
        /// The Splitwise activity feed.
        static let activity = "bell.fill"
        /// The queue of operations waiting to reach YNAB/Splitwise.
        static let pending = "arrow.triangle.2.circlepath"
        static let fileImport = "doc.badge.plus"
        /// Incomplete transaction drafts.
        static let drafts = "square.and.pencil"
        /// Destructive action — swipe-to-delete, delete toolbar buttons.
        static let delete = "trash.fill"
        /// Create a new transaction/template.
        static let add = "plus"
        /// An affirmative state: exported, selected, checklist step completed.
        static let checkmark = "checkmark"
        /// The not-yet counterpart to `checkmark` in onboarding checklists.
        static let unchecked = "circle"
        /// Dismisses the keyboard from a keyboard toolbar, for keyboard types
        /// with no return key of their own (`.decimalPad`, `.numberPad`).
        static let dismissKeyboard = "chevron.down"
        /// A later automation run recognised as the same purchase and dropped
        /// — see `TransactionClaim` and the "Duplicates Skipped" section.
        static let duplicateSkipped = "link"
        /// A pending operation that failed and is being retried.
        static let syncError = "exclamationmark.triangle.fill"
    }

    /// Header/method names and values shared by `YNABService`,
    /// `SplitwiseService`, and the two auth services.
    struct HTTP {
        static let post = "POST"
        static let authorizationHeader = "Authorization"
        static let contentTypeHeader = "Content-Type"
        static let retryAfterHeader = "Retry-After"
        static let jsonContentType = "application/json"

        /// Formats an access token as an `Authorization` header value. Only
        /// ever passed to YNAB's/Splitwise's own API and never logged, per the
        /// token-handling rules in CLAUDE.md.
        static func bearer(_ token: String) -> String { "Bearer \(token)" }
    }

    /// Documented values for YNAB's `cleared` transaction field.
    struct YNAB {
        static let cleared = "cleared"
        static let uncleared = "uncleared"
    }
}
