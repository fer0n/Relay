//
//  SplitwiseAuthService.swift
//  Relay
//
//  Splitwise only offers the authorization code grant, whose token exchange
//  needs a client secret — which can't live in the app, since anything compiled
//  into the binary is extractable. The exchange is delegated to the relay-auth
//  Cloudflare Worker (see ../../oauth-relay/README.md), the only place holding
//  the secret; this service only ever sends it an authorization `code`.
//

import AuthenticationServices
import Foundation
import Observation
import os

private let logger = Logger(subsystem: Const.loggerSubsystem, category: "SplitwiseAuthService")

@MainActor
@Observable
final class SplitwiseAuthService {
    private(set) var accessToken: String?
    /// Surfaced next to the Connect button — otherwise a failed token exchange
    /// looks like nothing happened, since the web page closes either way.
    private(set) var signInError: String?
    /// Raw text for the "Report Error" mail action; `signInError` stays friendly.
    private(set) var signInErrorDetail: String?
    private var session: ASWebAuthenticationSession?
    private let presentationContextProvider = AuthPresentationContextProvider()

    private nonisolated static let accessTokenKey = "splitwise.accessToken"
    private nonisolated static let refreshTokenKey = "splitwise.refreshToken"

    var isAuthenticated: Bool { accessToken != nil }

    /// Static, since App Intents contexts run without an owning instance.
    nonisolated static var currentAccessToken: String? {
        KeychainStore.load(for: accessTokenKey)
    }

    /// Clears the stored token once the API reports it's dead, so the app stops
    /// showing "Connected". Static for the same reason as above.
    nonisolated static func invalidateAccessToken() {
        KeychainStore.delete(for: accessTokenKey)
        KeychainStore.delete(for: refreshTokenKey)
    }

    init() {
        accessToken = KeychainStore.load(for: Self.accessTokenKey)
    }

    /// In case an App Intent invalidated the token while this instance was alive.
    func refreshFromKeychain() {
        accessToken = KeychainStore.load(for: Self.accessTokenKey)
    }

    func clearSignInError() {
        signInError = nil
        signInErrorDetail = nil
    }

    func signIn() {
        signInError = nil
        var components = URLComponents(string: "https://secure.splitwise.com/oauth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: OAuthConfig.splitwiseClientID),
            URLQueryItem(name: "redirect_uri", value: OAuthConfig.splitwiseRedirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "state", value: UUID().uuidString),
        ]

        let session = ASWebAuthenticationSession(
            url: components.url!,
            callbackURLScheme: OAuthConfig.callbackScheme
        ) { [weak self] callbackURL, _ in
            guard let self, let callbackURL else { return }
            Task { await self.exchangeCode(from: callbackURL) }
        }
        session.presentationContextProvider = presentationContextProvider
        self.session = session
        session.start()
    }

    private func exchangeCode(from url: URL) async {
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let code = components.queryItems?.first(where: { $0.name == "code" })?.value
        else { return }

        // Goes through the oauth-relay Worker, the only place holding
        // client_secret.
        var request = URLRequest(url: URL(string: OAuthConfig.oauthRelayBaseURL + "/splitwise/token")!)
        request.httpMethod = Const.HTTP.post
        request.setValue(Const.HTTP.jsonContentType, forHTTPHeaderField: Const.HTTP.contentTypeHeader)

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: ["code": code])
            let (data, _) = try await URLSession.shared.data(for: request)
            let token = try JSONDecoder().decode(SplitwiseTokenResponse.self, from: data)
            accessToken = token.accessToken
            KeychainStore.save(token.accessToken, for: Self.accessTokenKey)
            if let refreshToken = token.refreshToken {
                KeychainStore.save(refreshToken, for: Self.refreshTokenKey)
            }
            // Warms the friend cache, so offline template creation works without a
            // first online visit to the template editor.
            Task { _ = try? await SplitwiseFriendCacheStore.fetch(token: token.accessToken) }
            // And SplitwiseCurrentUserStore, which would otherwise stay empty until
            // the first expense is added — leaving every signed/colored amount
            // that depends on it falling back to the plain unsigned cost.
            Task {
                if let user = try? await SplitwiseService.fetchCurrentUser(token: token.accessToken) {
                    try? SplitwiseCurrentUserStore.save(user)
                }
            }
        } catch {
            logger.error("token exchange failed: \(String(describing: error), privacy: .public)")
            signInError = Self.signInErrorMessage(for: error)
            signInErrorDetail = String(describing: error)
        }
    }

    private static func signInErrorMessage(for error: Error) -> String {
        if error is URLError {
            return "Couldn't reach the sign-in service. Check your internet connection and try again."
        }
        return "Something went wrong while connecting to Splitwise. Please try again."
    }

    /// Disconnecting is the user's data-deletion request (see CLAUDE.md), so it
    /// drops everything read through the token too. None of it is reachable once
    /// signed out, so keeping it would leave data behind with no way to clear it.
    func signOut() {
        accessToken = nil
        KeychainStore.delete(for: Self.accessTokenKey)
        KeychainStore.delete(for: Self.refreshTokenKey)
        SplitwiseCurrentUserStore.delete()
        SplitwiseFriendCacheStore.delete()
        SplitwiseExpenseCacheStore.invalidateAll()
        SplitwiseNotificationCacheStore.delete()
    }
}

private struct SplitwiseTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
    }
}
