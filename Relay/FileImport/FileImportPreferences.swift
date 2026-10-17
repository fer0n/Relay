//
//  FileImportPreferences.swift
//  Relay
//
//  Settings a fresh file import starts from: the last "Include Memos" choice.
//

import Foundation

nonisolated enum FileImportPreferences {
    private static let includeMemosKey = "fileImportIncludeMemos"

    static var includeMemos: Bool {
        get { UserDefaults.standard.object(forKey: includeMemosKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: includeMemosKey) }
    }
}
