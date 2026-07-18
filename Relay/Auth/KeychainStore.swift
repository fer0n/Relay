//
//  KeychainStore.swift
//  Relay
//

import Foundation
import Security

enum KeychainStore {
    private static let service = "com.octabits.relay"

    /// `AfterFirstUnlock` rather than the default `WhenUnlocked`: the wallet
    /// App Intents run in the background (no `openAppWhenRun`), so they can
    /// fire while the device is locked. `WhenUnlocked` would make the token
    /// unreadable then, and the intent would throw `.notAuthenticated`
    /// despite a connected account. `AfterFirstUnlock` keeps the token
    /// device-only and encrypted at rest, but readable once the device has
    /// been unlocked at least once since boot — the standard class for
    /// credentials a background task needs.
    private static let accessibility = kSecAttrAccessibleAfterFirstUnlock

    static func save(_ value: String, for key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = accessibility
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func load(for key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(for key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
