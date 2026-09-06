//
//  AutomaticBackup.swift
//  Relay
//

import Foundation
import UIKit
import os

private nonisolated let logger = Logger(subsystem: Const.loggerSubsystem, category: "AutomaticBackup")

nonisolated enum AutomaticBackupPreference {
    private static let enabledKey = "backup.automaticEnabled"
    private static let lastRunKey = "backup.lastAutomaticRun"

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var lastRun: Date? {
        get { UserDefaults.standard.object(forKey: lastRunKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: lastRunKey) }
    }
}

@MainActor
enum AutomaticBackup {
    static func runIfNeeded(now: Date = Date()) async {
        guard AutomaticBackupPreference.isEnabled else { return }
        if let lastRun = AutomaticBackupPreference.lastRun,
           Calendar.current.isDate(lastRun, inSameDayAs: now) {
            return
        }
        do {
            _ = try await run(manual: false, now: now)
        } catch {
            logger.error("Automatic backup failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    @discardableResult
    static func run(manual: Bool, now: Date = Date()) async throws -> URL {
        let deviceName = UIDevice.current.name
        let data = try BackupService.encode(
            BackupService.makeBackupIncludingLedgers(deviceName: deviceName)
        )
        let url = try await Task.detached(priority: .utility) {
            let url = try ICloudBackupService.write(data, deviceName: deviceName, date: now, manual: manual)
            let deleted = ICloudBackupService.autoDelete(now: now)
            if deleted > 0 {
                logger.log("pruned \(deleted, privacy: .public) old backups")
            }
            return url
        }.value
        if !manual {
            AutomaticBackupPreference.lastRun = now
        }
        return url
    }

    /// Reads the newest stored backup and checks it against itself and
    /// against what's on the device right now.
    static func verifyLatestBackup() async -> LedgerBackupVerification? {
        let store = LedgerStore.shared
        let live = LedgerBackup(
            ledgers: store.ledgers,
            expenses: store.expenses,
            currentUserID: store.currentUserID
        )
        return await Task.detached(priority: .utility) { () -> LedgerBackupVerification? in
            guard let latest = ICloudBackupService.latestBackup(),
                  let backup = ICloudBackupService.loadBackup(at: latest.url) else { return nil }
            guard let ledgers = backup.ledgers else {
                return LedgerBackupVerification(ledgerCount: 0, expenseCount: 0, problems: [])
            }
            return LedgerBackupVerifier.crossReference(ledgers, with: live)
        }.value
    }
}
