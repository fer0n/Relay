//
//  ConnectivityError.swift
//  Relay
//
//  Distinguishes "no network right now" from a real API-level failure, so
//  only the former gets silently retried/queued by PendingSync and
//  PendingOperationQueue — retrying a 401/429/validation failure would just
//  fail the same way again forever.
//
//  Both transports are covered: URLError from YNAB's REST API, and CKError
//  from CloudKit, which reports the same condition as its own
//  `.networkUnavailable` / `.networkFailure` rather than as a URLError.
//

import CloudKit
import Foundation

extension Error {
    nonisolated var isConnectivityFailure: Bool {
        if let urlError = self as? URLError {
            return urlError.isConnectivityFailure
        }
        if let ckError = self as? CKError {
            return ckError.isConnectivityFailure
        }
        return false
    }
}

private extension URLError {
    nonisolated var isConnectivityFailure: Bool {
        switch code {
        case .notConnectedToInternet, .networkConnectionLost, .timedOut,
             .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
             .dataNotAllowed, .internationalRoamingOff, .callIsActive,
             .cannotLoadFromNetwork:
            return true
        default:
            return false
        }
    }
}

private extension CKError {
    /// `.serviceUnavailable` and `.requestRateLimited` are in here alongside
    /// the two network codes: all four mean "not now, try again", and unlike
    /// YNAB's rate limit there's no token to have permanently exhausted.
    /// `.partialFailure` wraps the real code once per item, and CloudKit also
    /// surfaces a plain URLError as the underlying error of an
    /// `.internalError`, so both are unwrapped rather than read at face value.
    nonisolated var isConnectivityFailure: Bool {
        switch code {
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited:
            return true
        case .partialFailure:
            let byItem = partialErrorsByItemID ?? [:]
            return !byItem.isEmpty && byItem.values.allSatisfy(\.isConnectivityFailure)
        default:
            return (userInfo[NSUnderlyingErrorKey] as? Error)?.isConnectivityFailure ?? false
        }
    }
}
