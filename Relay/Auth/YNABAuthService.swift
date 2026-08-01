//
//  YNABAuthService.swift
//  Relay
//
//  Uses YNAB's authorization code grant, the only one that issues a refresh
//  token — the implicit grant's 2-hour access token can't be renewed at all.
//  The trade-off is that its token exchange needs a client secret, which can't
//  live in the app (anything compiled into the binary is extractable), so the
//  exchange and refresh are delegated to the relay-auth Cloudflare Worker (see
//  ../../oauth-relay/README.md), the only place holding the secret. PKCE
//  (RFC 7636) is layered on top as defense in depth against code interception
//  via the shared "relay://" URL scheme.
//
//  Implicit-grant tokens saved before this keep working until they expire and a
//  real API call 401s; invalidateAccessToken() then clears them, and one more
//  manual signIn() starts recording a refresh token and expiry.
//

import AuthenticationServices
import CryptoKit
import Foundation
import Observation
import Security
import os

private nonisolated let logger = Logger(subsystem: Const.loggerSubsystem, category: "YNABAuthService")

@MainActor
@Observable
final class YNABAuthService {
    private(set) var accessToken: String?
    /// Surfaced next to the Connect button — otherwise a failed token exchange
    /// looks like nothing happened, since the web page closes either way.
    private(set) var signInError: String?
    /// Raw text for the "Report Error" mail action; `signInError` stays friendly.
    private(set) var signInErrorDetail: String?
    private var session: ASWebAuthenticationSession?
    private var pendingCodeVerifier: String?
    private let presentationContextProvider = AuthPresentationContextProvider()

    private nonisolated static let accessTokenKey = "ynab.accessToken"
    private nonisolated static let refreshTokenKey = "ynab.refreshToken"
    private nonisolated static let expiresAtKey = "ynab.accessTokenExpiresAt"

    var isAuthenticated: Bool { accessToken != nil }

    /// Refreshes silently when the token is expired or close to it. With no
    /// recorded expiry it returns whatever's stored — a real API call 401s and
    /// invalidates it if it's actually dead. Static, since App Intents contexts
    /// run without an owning instance.
    nonisolated static func validAccessToken() async -> String? {
        guard let accessToken = KeychainStore.load(for: accessTokenKey) else { return nil }
        guard
            let expiresAtString = KeychainStore.load(for: expiresAtKey),
            let expiresAt = TimeInterval(expiresAtString),
            Date(timeIntervalSince1970: expiresAt) < Date().addingTimeInterval(120)
        else {
            return accessToken
        }
        if let refreshed = await refreshAccessToken() {
            return refreshed
        }
        // Re-read rather than reuse the token captured above: an invalid-grant
        // failure wipes it, while a transient network failure leaves it in place
        // for a real API call to try.
        return KeychainStore.load(for: accessTokenKey)
    }

    /// Clears every stored credential once the API reports they're dead, so the
    /// app stops showing "Connected". Static for the same reason as above.
    nonisolated static func invalidateAccessToken() {
        KeychainStore.delete(for: accessTokenKey)
        KeychainStore.delete(for: refreshTokenKey)
        KeychainStore.delete(for: expiresAtKey)
    }

    init() {
        accessToken = KeychainStore.load(for: Self.accessTokenKey)
    }

    /// In case an App Intent invalidated or refreshed the token while this
    /// instance was already alive.
    func refreshFromKeychain() {
        accessToken = KeychainStore.load(for: Self.accessTokenKey)
    }

    func clearSignInError() {
        signInError = nil
        signInErrorDetail = nil
    }

    func signIn() {
        signInError = nil
        let codeVerifier = Self.generateCodeVerifier()
        pendingCodeVerifier = codeVerifier

        var components = URLComponents(string: "https://app.ynab.com/oauth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: OAuthConfig.ynabClientID),
            URLQueryItem(name: "redirect_uri", value: OAuthConfig.ynabRedirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "code_challenge", value: Self.codeChallenge(for: codeVerifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: UUID().uuidString),
        ]

        let session = ASWebAuthenticationSession(
            url: components.url!,
            callbackURLScheme: OAuthConfig.callbackScheme
        ) { [weak self] callbackURL, _ in
            guard let self, let callbackURL else { return }
            Task { await self.handleCallback(callbackURL) }
        }
        session.presentationContextProvider = presentationContextProvider
        self.session = session
        session.start()
    }

    private func handleCallback(_ url: URL) async {
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
            let codeVerifier = pendingCodeVerifier
        else { return }
        pendingCodeVerifier = nil

        do {
            let token = try await Self.requestToken(path: "/ynab/token", bodyParams: [
                "code": code,
                "code_verifier": codeVerifier,
            ])
            Self.save(token)
            accessToken = token.accessToken
            logger.log("YNAB sign-in succeeded")
            // Warms the caches, so offline template creation works without a
            // first online visit to the template editor.
            Task {
                _ = try? await YNABCategoryCacheStore.fetch(token: token.accessToken)
                _ = try? await YNABAccountCacheStore.fetch(token: token.accessToken)
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
        return "Something went wrong while connecting to YNAB. Please try again."
    }

    /// Drops the data read through the token as well as the token, so nothing
    /// pulled from YNAB is left on disk (see CLAUDE.md). Deliberately not in
    /// `invalidateAccessToken()`, which also runs on a merely expired token —
    /// there the caches are what keeps the pickers working until sign-in.
    func signOut() {
        accessToken = nil
        Self.invalidateAccessToken()
        YNABCategoryCacheStore.delete()
        YNABAccountCacheStore.delete()
    }

    // MARK: - Refresh

    private nonisolated static func refreshAccessToken() async -> String? {
        guard let refreshToken = KeychainStore.load(for: refreshTokenKey) else { return nil }
        do {
            let token = try await requestToken(path: "/ynab/refresh", bodyParams: [
                "refresh_token": refreshToken,
            ])
            save(token)
            logger.log("refreshed YNAB access token")
            return token.accessToken
        } catch YNABTokenExchangeError.invalidGrant {
            logger.error("refresh token rejected — clearing stored YNAB credentials")
            invalidateAccessToken()
            return nil
        } catch {
            logger.error("YNAB token refresh failed (treating as transient): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private nonisolated static func save(_ token: YNABTokenResponse) {
        KeychainStore.save(token.accessToken, for: accessTokenKey)
        KeychainStore.save(token.refreshToken, for: refreshTokenKey)
        let expiresAt = Date().addingTimeInterval(token.expiresIn).timeIntervalSince1970
        KeychainStore.save(String(expiresAt), for: expiresAtKey)
    }

    // MARK: - Token exchange

    /// Goes through the oauth-relay Worker rather than app.ynab.com/oauth/token,
    /// since the Worker is the only place holding client_secret.
    private nonisolated static func requestToken(path: String, bodyParams: [String: String]) async throws -> YNABTokenResponse {
        var request = URLRequest(url: URL(string: OAuthConfig.oauthRelayBaseURL + path)!)
        request.httpMethod = Const.HTTP.post
        request.setValue(Const.HTTP.jsonContentType, forHTTPHeaderField: Const.HTTP.contentTypeHeader)
        request.httpBody = try JSONSerialization.data(withJSONObject: bodyParams)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw YNABTokenExchangeError.other }
        // The relay passes YNAB's status through unchanged, and YNAB returns 400
        // for both a malformed request and a dead refresh token (`invalid_grant`)
        // — treated as the latter, since that's the case worth reacting to.
        if http.statusCode == 400 { throw YNABTokenExchangeError.invalidGrant }
        guard (200...299).contains(http.statusCode) else { throw YNABTokenExchangeError.other }
        return try JSONDecoder().decode(YNABTokenResponse.self, from: data)
    }

    // MARK: - PKCE

    private static func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    private static func codeChallenge(for verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).base64URLEncodedString()
    }
}

private nonisolated enum YNABTokenExchangeError: Error {
    case invalidGrant
    case other
}

private nonisolated struct YNABTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: TimeInterval

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
