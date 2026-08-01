//
//  Bundle+Version.swift
//  Relay
//

import Foundation

extension Bundle {
    /// e.g. "v1.2 (34)", for display in Settings.
    var versionAndBuildNumber: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
        let build = infoDictionary?["CFBundleVersion"] as? String
        return build.map { "v\(version) (\($0))" } ?? "v\(version)"
    }
}
