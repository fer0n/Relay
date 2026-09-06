//
//  BackupRetentionTests.swift
//  RelayTests
//
//  Thinning is the only thing in the backup path that deletes, so the rules
//  are worth pinning down: a run of daily files has to collapse without ever
//  taking the newest one, or a file the user made themselves.
//

import Foundation
import Testing
@testable import Relay

struct BackupRetentionTests {
    private static let now = Date(timeIntervalSince1970: 1_760_000_000)

    private static func file(daysAgo: Int, manual: Bool = false) -> BackupFileInfo {
        let date = now.addingTimeInterval(TimeInterval(-daysAgo) * 24 * 60 * 60)
        return BackupFileInfo(
            url: URL(fileURLWithPath: "/backups/\(daysAgo)\(manual ? "m" : "").json"),
            date: date,
            isManual: manual
        )
    }

    private static func deleted(_ files: [BackupFileInfo]) -> Set<URL> {
        Set(BackupRetention.filesToDelete(files, now: now).map(\.url))
    }

    @Test
    func keepsEverythingFromTheLastWeek() {
        let files = (0..<7).map { Self.file(daysAgo: $0) }

        #expect(Self.deleted(files).isEmpty)
    }

    @Test
    func keepsOneBackupPerWeekWithinHalfAYear() {
        let files = (8...120).map { Self.file(daysAgo: $0) }
        let deleted = Self.deleted(files)
        let kept = files.filter { !deleted.contains($0.url) }

        let calendar = Calendar(identifier: .gregorian)
        let weeks = kept.map { file in
            "\(calendar.component(.year, from: file.date))-\(calendar.component(.weekOfYear, from: file.date))"
        }

        #expect(kept.count == Set(weeks).count)
        #expect(kept.count < files.count / 5)
    }

    @Test
    func neverDeletesTheNewestBackup() {
        let files = (0...400).map { Self.file(daysAgo: $0) }
        let newest = Self.file(daysAgo: 0)

        #expect(!Self.deleted(files).contains(newest.url))
    }

    @Test
    func keepsManualBackupsForever() {
        let manual = Self.file(daysAgo: 900, manual: true)
        let files = [manual] + (0...900).map { Self.file(daysAgo: $0) }

        #expect(!Self.deleted(files).contains(manual.url))
    }

    @Test
    func thinsOutYearsOfDailyBackups() {
        let files = (0...1000).map { Self.file(daysAgo: $0) }

        let kept = files.count - Self.deleted(files).count

        #expect(kept < 50)
        #expect(kept > 7)
    }

    @Test
    func fileNamesRoundTripTheirDateAndKind() {
        let date = Date(timeIntervalSince1970: 1_760_000_000)
        let automatic = BackupFileName.make(deviceName: "Michael's iPhone", date: date, manual: false)
        let manual = BackupFileName.make(deviceName: "Michael's iPhone", date: date, manual: true)

        #expect(BackupFileName.date(from: automatic) == date)
        #expect(BackupFileName.date(from: manual) == date)
        #expect(!BackupFileName.isManual(automatic))
        #expect(BackupFileName.isManual(manual))
        #expect(automatic.hasSuffix(".json"))
        #expect(!automatic.contains("'"))
    }

    @Test
    func ignoresFilesItDidntWrite() {
        #expect(BackupFileName.date(from: "notes.json") == nil)
        #expect(BackupFileName.date(from: "Relay-iPhone-nonsense.json") == nil)
        #expect(BackupFileInfo(url: URL(fileURLWithPath: "/backups/notes.json")) == nil)
    }
}
