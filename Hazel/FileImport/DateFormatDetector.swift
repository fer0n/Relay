//
//  DateFormatDetector.swift
//  Hazel
//
//  Ports get_date_format from the original "YNAB Toolkit" Shortcut's
//  Pythonista script (~/Downloads/YNAB Toolkit.txt): tries a fixed list of
//  candidate date formats against a handful of sample date strings from the
//  statement file, and only asks the user when that isn't enough to narrow
//  it down to exactly one.
//

import Foundation

nonisolated enum DateFormatDetector {
    /// Numeric variants cover the vast majority of bank exports. Month-name
    /// variants assume English month names (parsed with `en_US_POSIX`) —
    /// a simplification versus the Python original, which relied on
    /// Pythonista's locale at run time.
    static let candidateFormats = [
        "dd/MM/yyyy",
        "dd/MM/yy",
        "dd/MMM/yyyy",
        "dd/MMMM/yyyy",
        "dd.MM.yyyy",
        "dd.MM.yy",
        "dd-MM-yyyy",
        "dd-MM-yy",
        "MM/dd/yy",
        "MM/dd/yyyy",
        "MM-dd-yyyy",
        "MM/dd'yyyy",
        "yyyy/MM/dd",
        "yyyy.MM.dd",
        "yyyy-MM-dd",
        "yyyy/dd/MM",
    ]

    enum Result {
        /// Exactly one candidate format parsed every sample — no need to ask.
        case detected(String)
        /// Zero or more than one candidate matched; the caller must ask the
        /// user to pick among these (the full candidate list if none
        /// matched, or just the ambiguous subset otherwise).
        case needsDisambiguation(candidates: [String])
    }

    /// - Parameter samples: a handful of distinct date strings taken from
    ///   the file, e.g. one per unique value seen so far.
    static func detect(samples: [String]) -> Result {
        let matching = candidateFormats.filter { format in
            samples.allSatisfy { parse($0, format: format) != nil }
        }
        if matching.count == 1 {
            return .detected(matching[0])
        }
        return .needsDisambiguation(candidates: matching.isEmpty ? candidateFormats : matching)
    }

    static func parse(_ dateString: String, format: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.isLenient = false
        formatter.dateFormat = format
        guard let date = formatter.date(from: dateString) else { return nil }
        // DateFormatter can be surprisingly loose about separator characters
        // and field width even with isLenient = false (e.g. a "/"-separated
        // format matching a "."-separated string, or "yy" swallowing a
        // 4-digit year) — round-tripping catches those false positives,
        // which otherwise made near-duplicate formats spuriously ambiguous.
        guard formatter.string(from: date) == dateString else { return nil }
        return date
    }
}
