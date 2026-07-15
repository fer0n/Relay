//
//  NotificationsPreferenceStore.swift
//  Hazel
//
//  The in-app Notifications toggle only ever controls this flag — it never
//  touches the OS permission directly (there's no API to revoke it from
//  inside the app anyway). TransactionDraftGuard checks this before
//  scheduling a reminder, so turning the toggle off silences reminders
//  even though the OS permission itself stays granted.
//

import Foundation

enum NotificationsPreferenceStore {
    private static let key = "notifications.userEnabled"

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
