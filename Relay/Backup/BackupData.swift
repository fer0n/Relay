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
//    - Auth tokens. YNAB's Terms of Service forbid exporting
//      access tokens anywhere but their own APIs (see CLAUDE.md); the user
//      re-authenticates after restoring. Tokens live only in the Keychain.
//    - API caches (YNAB categories and accounts).
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

nonisolated struct BackupData: Codable {
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
    var notificationsEnabled: Bool?
    var ynabCategoryUsage: YNABCategoryUsage?
    var ledgerParticipantUsage: LedgerParticipantUsage?
    var fileImportHistory: FileImportHistory?

    /// Read-only: a copy of the ledgers and their expenses, with per-ledger
    /// totals and a checksum to check it against. Restore never writes it
    /// back — the CloudKit share can only be re-established from iCloud, so
    /// importing a copy would create a second, unshared list rather than
    /// rejoining the real one.
    var ledgers: LedgerBackup?
    var createdAt: Date?
    var deviceName: String?

    /// 2 dropped the Splitwise sections (`splitwiseDefaultFriend`,
    /// `splitwiseFriendUsage`); 3 added the ledger copy above. Older backups
    /// still restore everything else.
    static let currentVersion = 3
}
