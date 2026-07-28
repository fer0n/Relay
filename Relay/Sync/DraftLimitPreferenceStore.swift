//
//  DraftLimitPreferenceStore.swift
//  Relay
//
//  Caps how many transaction drafts (see TransactionDraftStore) can exist at
//  once — TransactionDraftGuard.create() trims the oldest ones beyond this
//  count after adding a new one, same pattern as TransactionHistoryStore's
//  fixed historyLimit, just user-configurable.
//

import Foundation

nonisolated enum DraftLimitPreferenceStore {
    private static let key = "drafts.maxKept"
    static let options = [5, 10, 20, 30, 50]
    static let defaultLimit = 30

    static var limit: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: key)
            return options.contains(stored) ? stored : defaultLimit
        }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
