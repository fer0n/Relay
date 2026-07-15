//
//  SplitwiseIntentError.swift
//  Hazel
//

import AppIntents

nonisolated enum SplitwiseIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notAuthenticated
    case rateLimited
    case requestFailed
    case validation(String)
    case unsupportedFileType
    case invalidFile(reason: String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notAuthenticated:
            return "Open Hazel and connect your Splitwise account first."
        case .rateLimited:
            return "Splitwise is rate-limiting requests right now. Try again in a few minutes."
        case .requestFailed:
            return "Couldn't add the expense. Please try again."
        case .validation(let message):
            return "\(message)"
        case .unsupportedFileType:
            return "Hazel can only import .csv or .qif files."
        case .invalidFile(let reason):
            return "Couldn't read that file: \(reason)"
        }
    }

    /// Maps a low-level API error to an intent-facing one, so Splitwise's
    /// access token is never surfaced and expired-token cases point at re-auth.
    static func from(_ error: Error) -> SplitwiseIntentError {
        switch error {
        case SplitwiseAPIError.unauthorized:
            // Clears the stale token so Hazel's own UI shows "Not
            // Connected" instead of silently failing on every Splitwise call.
            SplitwiseAuthService.invalidateAccessToken()
            return .notAuthenticated
        case SplitwiseAPIError.rateLimited:
            return .rateLimited
        case SplitwiseAPIError.validation(let message):
            return .validation(message)
        case StatementImportError.unsupportedFileType:
            return .unsupportedFileType
        case StatementImportError.invalidFile(let reason):
            return .invalidFile(reason: reason)
        default:
            return .requestFailed
        }
    }
}
