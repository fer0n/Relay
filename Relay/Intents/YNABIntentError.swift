//
//  YNABIntentError.swift
//  Relay
//

import AppIntents

nonisolated enum YNABIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notAuthenticated
    case noDefaultBudget
    case rateLimited
    case requestFailed
    case unsupportedFileType
    case invalidFile(reason: String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notAuthenticated:
            return "Open Relay and connect your YNAB account first."
        case .noDefaultBudget:
            return "No default YNAB budget is set for this account. Reconnect YNAB in Relay and choose a default budget when prompted."
        case .rateLimited:
            return "YNAB is rate-limiting requests right now. Try again in a few minutes."
        case .requestFailed:
            return "Couldn't add the transaction. Please try again."
        case .unsupportedFileType:
            return "Relay can only import .csv or .qif files."
        case .invalidFile(let reason):
            return "Couldn't read that file: \(reason)"
        }
    }

    /// Maps a low-level API error to an intent-facing one, so YNAB's access
    /// token is never surfaced and expired-token cases point at re-auth.
    static func from(_ error: Error) -> YNABIntentError {
        switch error {
        case YNABAPIError.unauthorized:
            // Clears the stale token so Relay's own UI shows "Not
            // Connected" instead of silently failing on every YNAB call.
            YNABAuthService.invalidateAccessToken()
            return .notAuthenticated
        case YNABAPIError.rateLimited:
            return .rateLimited
        case YNABAPIError.server(let status) where status == 404:
            return .noDefaultBudget
        case StatementImportError.unsupportedFileType:
            return .unsupportedFileType
        case StatementImportError.invalidFile(let reason):
            return .invalidFile(reason: reason)
        default:
            return .requestFailed
        }
    }

    /// A user-facing message for any error thrown out of a YNAB call: an
    /// already-typed intent error is kept as-is, anything else is mapped via
    /// `from(_:)` (which strips the token and points auth failures at
    /// re-auth). Collapses the `(error as? Self) ?? .from(error)` +
    /// `String(localized:)` dance the call sites would otherwise each repeat.
    static func message(for error: Error) -> String {
        String(localized: ((error as? YNABIntentError) ?? from(error)).localizedStringResource)
    }
}
