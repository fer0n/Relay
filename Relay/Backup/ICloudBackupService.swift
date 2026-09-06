//
//  ICloudBackupService.swift
//  Relay
//

import Foundation
import os

private nonisolated let logger = Logger(subsystem: Const.loggerSubsystem, category: "ICloudBackup")

nonisolated enum ICloudBackupError: LocalizedError {
    case iCloudUnavailable

    var errorDescription: String? {
        switch self {
        case .iCloudUnavailable:
            return String(localized: "iCloud Drive isn't available. Turn it on in Settings to store backups.")
        }
    }
}

nonisolated enum ICloudBackupService {
    static let directoryName = "Backups"

    static func backupsDirectory(createIfMissing: Bool = true) -> URL? {
        guard let container = FileManager.default.url(forUbiquityContainerIdentifier: nil) else { return nil }
        let directory = container
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            guard createIfMissing else { return nil }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                logger.error("Creating backups directory failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        return directory
    }

    @discardableResult
    static func write(_ data: Data, deviceName: String, date: Date = Date(), manual: Bool) throws -> URL {
        guard let directory = backupsDirectory() else { throw ICloudBackupError.iCloudUnavailable }
        let url = directory.appendingPathComponent(
            BackupFileName.make(deviceName: deviceName, date: date, manual: manual)
        )
        try data.write(to: url, options: .atomic)
        return url
    }

    static func backupFiles() -> [BackupFileInfo] {
        guard let directory = backupsDirectory(createIfMissing: false),
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        return names
            .compactMap { BackupFileInfo(url: directory.appendingPathComponent($0)) }
            .sorted { $0.date > $1.date }
    }

    static func latestBackup() -> BackupFileInfo? {
        backupFiles().first
    }

    static func loadBackup(at url: URL) -> BackupData? {
        var coordinationError: NSError?
        var loaded: BackupData?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
            guard let data = try? Data(contentsOf: readURL) else { return }
            loaded = BackupService.decodeBackup(from: data)
        }
        if let coordinationError {
            logger.error("Reading backup failed: \(coordinationError.localizedDescription, privacy: .public)")
        }
        return loaded
    }

    @discardableResult
    static func autoDelete(now: Date = Date()) -> Int {
        let stale = BackupRetention.filesToDelete(backupFiles(), now: now)
        var deleted = 0
        for file in stale {
            do {
                try FileManager.default.removeItem(at: file.url)
                deleted += 1
            } catch {
                logger.error("Deleting backup failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return deleted
    }
}
