//
//  YNABIntentError.swift
//  Hazel
//

import AppIntents

nonisolated enum YNABIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notAuthenticated
    case noBudget
    case rateLimited
    case requestFailed

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notAuthenticated:
            return "Open Hazel and connect your YNAB account first."
        case .noBudget:
            return "No YNAB budget was found for this account."
        case .rateLimited:
            return "YNAB is rate-limiting requests right now. Try again in a few minutes."
        case .requestFailed:
            return "Couldn't add the transaction. Please try again."
        }
    }

    /// Maps a low-level API error to an intent-facing one, so YNAB's access
    /// token is never surfaced and expired-token cases point at re-auth.
    static func from(_ error: Error) -> YNABIntentError {
        switch error {
        case YNABAPIError.unauthorized:
            return .notAuthenticated
        case YNABAPIError.rateLimited:
            return .rateLimited
        case YNABAPIError.noBudget:
            return .noBudget
        default:
            return .requestFailed
        }
    }
}
