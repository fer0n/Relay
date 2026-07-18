//
//  LegacyBucketMigrationShortcut.swift
//  Relay
//
//  Handoff to the "YNAB Toolkit → Relay Migration" Shortcut, which reads the old
//  "Transaction → YNAB" Shortcut's DataJar buckets/merchants/cards and hands
//  them to Relay's Import Template File action. Relay only needs to open the
//  shortcut and listen for its x-callback-url completion — the parsing and
//  import themselves happen inside the Shortcut, not here.
//

import Foundation

enum LegacyBucketMigrationShortcut {
    static let name = "YNAB Toolkit → Relay Migration"
    static let installURL = URL(string: "https://www.icloud.com/shortcuts/e453df325e7e432a911405e091e44e5f")!

    /// Hosts used on the "relay://" scheme already registered for OAuth — a
    /// Shortcut run via x-callback-url opens x-success on completion or
    /// x-error (with an "errorMessage" query item attached automatically by
    /// iOS) if it fails or is cancelled.
    static let successHost = "legacy-migration-success"
    static let errorHost = "legacy-migration-error"

    static var runURL: URL {
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "x-callback-url"
        components.path = "/run-shortcut"
        components.queryItems = [
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "x-success", value: "relay://\(successHost)"),
            URLQueryItem(name: "x-error", value: "relay://\(errorHost)"),
        ]
        return components.url!
    }
}
