//
//  ConnectivityError.swift
//  Hazel
//
//  Distinguishes "no network right now" from a real API-level failure, so
//  only the former gets silently retried/queued by PendingSync and
//  PendingOperationQueue — retrying a 401/429/validation failure would just
//  fail the same way again forever.
//

import Foundation

extension Error {
    nonisolated var isConnectivityFailure: Bool {
        guard let urlError = self as? URLError else { return false }
        switch urlError.code {
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
