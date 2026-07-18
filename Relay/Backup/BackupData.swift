//
//  BackupData.swift
//  Relay
//
//  The full-backup file format written by Settings' "Export Backup" and read
//  back by "Import Backup" (and the "Import Templates" Shortcut, which now
//  also accepts a full backup). Supersedes the old template-only export,
//  which serialized a bare WalletTransactionConfig — that shape (and the
//  even older "YNAB Toolkit" bucket file) still import via
//  TemplateImportService's fallback path, so existing exports keep working.
//
//  What's in a backup: every piece of durable, user-authored configuration
//  and learned preference that would be painful to recreate on a new device.
//  What's deliberately NOT in a backup:
//    - Auth tokens. YNAB's and Splitwise's Terms of Service forbid exporting
//      access tokens anywhere but their own APIs (see CLAUDE.md); the user
//      re-authenticates after restoring. Tokens live only in the Keychain.
//    - API caches (YNAB categories/accounts, Splitwise friends/current user).
//      Regenerated on the next fetch, so there's no point carrying them.
//    - In-flight / transient state (transaction drafts, the pending-operation
//      sync queue, the recent-transaction log, the staged file import).
//      Restoring a stale snapshot of these could re-create transactions that
//      already synced, so they're intentionally left out.
//
//  Every field except `formatVersion` is optional so a backup written by a
//  newer build (with sections this build doesn't know about) — or an older
//  one missing sections — still restores whatever it does understand.
//

import Foundation

struct BackupData: Codable {
    /// Bumped when the schema changes in a way older builds can't read.
    /// Its *presence* is also the discriminator that lets import tell a full
    /// backup apart from a bare template export or the legacy bucket file:
    /// those don't carry this key, so decoding them as BackupData fails and
    /// import falls through to the older-format paths. Because it's the only
    /// required field, BackupData must be tried *first* during import —
    /// WalletTransactionConfig's fields all have defaults and would otherwise
    /// swallow a backup as an empty config.
    let formatVersion: Int

    var walletTransactionConfig: WalletTransactionConfig?
    var fileImportConfig: FileImportConfig?
    var splitwiseDefaultFriend: SplitwiseDefaultFriend?
    var notificationsEnabled: Bool?
    var ynabCategoryUsage: YNABCategoryUsage?
    var splitwiseFriendUsage: SplitwiseFriendUsage?
    var fileImportHistory: FileImportHistory?

    static let currentVersion = 1
}
