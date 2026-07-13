//
//  YNABAuthService.swift
//  Hazel
//
//  YNAB has no public-client-safe authorization code flow (the code grant
//  requires a client secret); the implicit grant is what YNAB recommends
//  for apps that can't keep a secret. Trade-off: no refresh token, access
//  token expires after 2 hours and the user re-authenticates via signIn().
//

import AuthenticationServices
import Foundation
import Observation

@MainActor
@Observable
final class YNABAuthService {
    private(set) var accessToken: String?
    private var session: ASWebAuthenticationSession?
    private let presentationContextProvider = AuthPresentationContextProvider()

    private static let keychainKey = "ynab.accessToken"

    var isAuthenticated: Bool { accessToken != nil }

    /// Reads the token directly from the Keychain, for use in contexts (like
    /// App Intents) that run without an owning `YNABAuthService` instance.
    nonisolated static var currentAccessToken: String? {
        KeychainStore.load(for: keychainKey)
    }

    /// Clears the stored token once the API reports it's no longer valid
    /// (expired/revoked), so the app stops showing "Connected" for a token
    /// that no longer works. Called from App Intents contexts too, which
    /// run without an owning `YNABAuthService` instance.
    nonisolated static func invalidateAccessToken() {
        KeychainStore.delete(for: keychainKey)
    }

    init() {
        accessToken = KeychainStore.load(for: Self.keychainKey)
    }

    /// Re-reads the Keychain, in case an App Intent invalidated the token
    /// (see `invalidateAccessToken()`) while this instance was already alive.
    func refreshFromKeychain() {
        accessToken = KeychainStore.load(for: Self.keychainKey)
    }

    func signIn() {
        var components = URLComponents(string: "https://app.ynab.com/oauth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: Secrets.ynabClientID),
            URLQueryItem(name: "redirect_uri", value: OAuthConfig.ynabRedirectURI),
            URLQueryItem(name: "response_type", value: "token"),
            URLQueryItem(name: "state", value: UUID().uuidString),
        ]

        let session = ASWebAuthenticationSession(
            url: components.url!,
            callbackURLScheme: OAuthConfig.callbackScheme
        ) { [weak self] callbackURL, _ in
            guard let self, let callbackURL else { return }
            self.handleCallback(callbackURL)
        }
        session.presentationContextProvider = presentationContextProvider
        self.session = session
        session.start()
    }

    private func handleCallback(_ url: URL) {
        guard let fragment = url.fragment else { return }
        let params = fragment
            .split(separator: "&")
            .reduce(into: [String: String]()) { result, pair in
                let parts = pair.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { return }
                result[String(parts[0])] = String(parts[1]).removingPercentEncoding
            }
        guard let token = params["access_token"] else { return }
        accessToken = token
        KeychainStore.save(token, for: Self.keychainKey)
    }

    func signOut() {
        accessToken = nil
        KeychainStore.delete(for: Self.keychainKey)
    }
}
