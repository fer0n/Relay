//
//  BackupRetention.swift
//  Relay
//

import Foundation

nonisolated struct BackupFileInfo: Equatable, Hashable, Sendable {
    let url: URL
    let date: Date
    let isManual: Bool

    init(url: URL, date: Date, isManual: Bool) {
        self.url = url
        self.date = date
        self.isManual = isManual
    }

    init?(url: URL) {
        guard let date = BackupFileName.date(from: url.lastPathComponent) else { return nil }
        self.init(url: url, date: date, isManual: BackupFileName.isManual(url.lastPathComponent))
    }
}

nonisolated enum BackupFileName {
    static let fileExtension = "json"
    static let prefix = "Relay"
    private static let manualMarker = "-m"

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()

    static func make(deviceName: String, date: Date, manual: Bool) -> String {
        let device = sanitize(deviceName)
        let stamp = dateFormatter.string(from: date)
        return "\(prefix)-\(device)-\(stamp)\(manual ? manualMarker : "").\(fileExtension)"
    }

    static func date(from fileName: String) -> Date? {
        guard fileName.hasSuffix(".\(fileExtension)"), fileName.hasPrefix("\(prefix)-") else { return nil }
        let base = fileName.dropLast(fileExtension.count + 1)
        let stamped = base.hasSuffix(manualMarker) ? base.dropLast(manualMarker.count) : base
        guard let separator = stamped.lastIndex(of: "-") else { return nil }
        return dateFormatter.date(from: String(stamped[stamped.index(after: separator)...]))
    }

    static func isManual(_ fileName: String) -> Bool {
        fileName.hasSuffix("\(manualMarker).\(fileExtension)")
    }

    private static func sanitize(_ deviceName: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let cleaned = deviceName.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let trimmed = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return trimmed.isEmpty ? "Device" : String(trimmed.prefix(40))
    }
}

nonisolated enum BackupRetention {
    static func filesToDelete(_ files: [BackupFileInfo], now: Date = Date()) -> [BackupFileInfo] {
        let keepers = keeperURLs(files, now: now)
        return files.filter { !keepers.contains($0.url) }
    }

    private static func keeperURLs(_ files: [BackupFileInfo], now: Date) -> Set<URL> {
        let calendar = Calendar(identifier: .gregorian)
        guard let oneWeekAgo = calendar.date(byAdding: .weekOfYear, value: -1, to: now),
              let halfYearAgo = calendar.date(byAdding: .month, value: -6, to: now),
              let oneYearAgo = calendar.date(byAdding: .year, value: -1, to: now) else {
            return Set(files.map(\.url))
        }

        var keepers = Set<URL>()
        var weekly: [String: BackupFileInfo] = [:]
        var monthly: [String: BackupFileInfo] = [:]
        var halfYearly: [String: BackupFileInfo] = [:]

        func bucketKey(_ date: Date, _ component: Calendar.Component) -> String {
            "\(calendar.component(.year, from: date))-\(calendar.component(component, from: date))"
        }

        func keepNewest(_ file: BackupFileInfo, in bucket: inout [String: BackupFileInfo], key: String) {
            guard let existing = bucket[key] else {
                bucket[key] = file
                return
            }
            if file.date > existing.date { bucket[key] = file }
        }

        for file in files.sorted(by: { $0.date > $1.date }) {
            if file.isManual || file.date >= oneWeekAgo {
                keepers.insert(file.url)
            } else if file.date >= halfYearAgo {
                keepNewest(file, in: &weekly, key: bucketKey(file.date, .weekOfYear))
            } else if file.date >= oneYearAgo {
                keepNewest(file, in: &monthly, key: bucketKey(file.date, .month))
            } else {
                let half = calendar.component(.month, from: file.date) <= 6 ? 1 : 2
                keepNewest(file, in: &halfYearly, key: "\(calendar.component(.year, from: file.date))-H\(half)")
            }
        }

        for bucket in [weekly, monthly, halfYearly] {
            keepers.formUnion(bucket.values.map(\.url))
        }
        return keepers
    }
}
