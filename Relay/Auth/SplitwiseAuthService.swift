//
//  SplitwiseAuthService.swift
//  Relay
//
//  Splitwise only offers the authorization code grant, which requires a
//  client secret for the token exchange — one that can't live in the app
//  once Relay is distributed to more than one device, since anything
//  compiled into the binary is extractable from any install. The actual
//  exchange is delegated to the relay-auth Cloudflare Worker (see
//  ../../oauth-relay/README.md), the only place that holds the secret;
//  this service only ever sends it an authorization `code`, never the
//  secret itself.
//

import AuthenticationServices
import Foundation
import Observation
import os

private let logger = Logger(subsystem: "com.octabits.relay", category: "SplitwiseAuthService")

@MainActor
@Observable
final class SplitwiseAuthService {
    private(set) var accessToken: String?
    /// Set when the interactive sign-in's token exchange fails, so the view
    /// showing the Connect button can surface it — otherwise the flow looks
    /// like it did nothing (the web sign-in page closes either way).
    private(set) var signInError: String?
    /// Raw error text for the "Report Error" mail action — `signInError`
    /// itself stays a friendly, generic message.
    private(set) var signInErrorDetail: String?
    private var session: ASWebAuthenticationSession?
    private let presentationContextProvider = AuthPresentationContextProvider()

    private static let accessTokenKey = "splitwise.accessToken"
    private static let refreshTokenKey = "splitwise.refreshToken"

    var isAuthenticated: Bool { accessToken != nil }

    /// Reads the token directly from the Keychain, for use in contexts (like
    /// App Intents) that run without an owning `SplitwiseAuthService` instance.
    nonisolated static var currentAccessToken: String? {
        KeychainStore.load(for: accessTokenKey)
    }

    /// Clears the stored token once the API reports it's no longer valid,
    /// so the app stops showing "Connected" for a token that no longer
    /// works. Called from App Intents contexts too, which run without an
    /// owning `SplitwiseAuthService` instance.
    nonisolated static func invalidateAccessToken() {
        KeychainStore.delete(for: accessTokenKey)
        KeychainStore.delete(for: refreshTokenKey)
    }

    init() {
        accessToken = KeychainStore.load(for: Self.accessTokenKey)
    }

    /// Re-reads the Keychain, in case an App Intent invalidated the token
    /// (see `invalidateAccessToken()`) while this instance was already alive.
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

        // Calls the oauth-relay Worker rather than secure.splitwise.com/
        // oauth/token directly — the Worker is the only place holding
        // client_secret.
        var request = URLRequest(url: URL(string: OAuthConfig.oauthRelayBaseURL + "/splitwise/token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: ["code": code])
            let (data, _) = try await URLSession.shared.data(for: request)
            let token = try JSONDecoder().decode(SplitwiseTokenResponse.self, from: data)
            accessToken = token.accessToken
            KeychainStore.save(token.accessToken, for: Self.accessTokenKey)
            if let refreshToken = token.refreshToken {
                KeychainStore.save(refreshToken, for: Self.refreshTokenKey)
            }
            // Warms the friend cache right away, so a fresh sign-in doesn't
            // need a first online visit to a template editor before
            // offline template creation works.
            Task { _ = try? await SplitwiseFriendCacheStore.fetch(token: token.accessToken) }
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

    func signOut() {
        accessToken = nil
        KeychainStore.delete(for: Self.accessTokenKey)
        KeychainStore.delete(for: Self.refreshTokenKey)
        SplitwiseCurrentUserStore.delete()
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
