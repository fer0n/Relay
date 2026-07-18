//
//  YNABAuthService.swift
//  Relay
//
//  YNAB's authorization code grant is the only one that issues a refresh
//  token — the implicit grant this used to use has a fixed 2-hour access
//  token with no way to renew it, forcing a re-`signIn()` every couple of
//  hours. The trade-off: the code grant's token exchange requires a client
//  secret, which can't live in the app once Relay is distributed to more
//  than one device — anything compiled into the binary is extractable from
//  any install. The actual token exchange (and refresh) is delegated to the
//  relay-auth Cloudflare Worker (see ../../oauth-relay/README.md),
//  the only place that holds the secret; this service only ever sends it a
//  `code`/`code_verifier` or `refresh_token`, never the secret itself.
//  PKCE (RFC 7636) is layered on top of that for defense in depth against a
//  code-interception attack via the shared "relay://" URL scheme.
//
//  Tokens saved before this change (implicit grant, no refresh token, no
//  recorded expiry) keep working as-is until they naturally expire and a
//  real API call 401s — at that point invalidateAccessToken() clears them
//  and the user does one more manual signIn(), which starts recording a
//  refresh token and expiry going forward.
//

import AuthenticationServices
import CryptoKit
import Foundation
import Observation
import Security
import os

private let logger = Logger(subsystem: "com.octabits.relay", category: "YNABAuthService")

@MainActor
@Observable
final class YNABAuthService {
    private(set) var accessToken: String?
    /// Set when the interactive sign-in's token exchange fails, so the view
    /// showing the Connect button can surface it — otherwise the flow looks
    /// like it did nothing (the web sign-in page closes either way).
    private(set) var signInError: String?
    /// Raw error text for the "Report Error" mail action — `signInError`
    /// itself stays a friendly, generic message.
    private(set) var signInErrorDetail: String?
    private var session: ASWebAuthenticationSession?
    private var pendingCodeVerifier: String?
    private let presentationContextProvider = AuthPresentationContextProvider()

    private static let accessTokenKey = "ynab.accessToken"
    private static let refreshTokenKey = "ynab.refreshToken"
    private static let expiresAtKey = "ynab.accessTokenExpiresAt"

    var isAuthenticated: Bool { accessToken != nil }

    /// Returns a still-valid access token, silently refreshing it first if
    /// it's expired (or close to it) and a refresh token is on file. Falls
    /// back to whatever's stored if there's no recorded expiry (a token
    /// saved before refresh support existed) — a real API call will 401
    /// and invalidate it via YNABIntentError if it's actually dead. Called
    /// from App Intents contexts too, which run without an owning
    /// `YNABAuthService` instance.
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
        // Refresh failed — re-read rather than reuse the token captured
        // above, since a definitive invalid-grant failure wipes it via
        // invalidateAccessToken() while a transient network failure
        // leaves it in place (worth letting a real API call try).
        return KeychainStore.load(for: accessTokenKey)
    }

    /// Clears every stored credential once the API (or a refresh attempt)
    /// reports they're no longer valid, so the app stops showing
    /// "Connected" for credentials that no longer work. Called from App
    /// Intents contexts too, which run without an owning
    /// `YNABAuthService` instance.
    nonisolated static func invalidateAccessToken() {
        KeychainStore.delete(for: accessTokenKey)
        KeychainStore.delete(for: refreshTokenKey)
        KeychainStore.delete(for: expiresAtKey)
    }

    init() {
        accessToken = KeychainStore.load(for: Self.accessTokenKey)
    }

    /// Re-reads the Keychain, in case an App Intent invalidated or
    /// silently refreshed the token while this instance was already alive.
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
            // Warms the category/account caches right away, so a fresh
            // sign-in doesn't need a first online visit to a template
            // editor before offline template creation works.
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

    func signOut() {
        accessToken = nil
        Self.invalidateAccessToken()
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

    /// Calls the oauth-relay Worker rather than app.ynab.com/oauth/token
    /// directly — the Worker is the only place holding client_secret.
    private nonisolated static func requestToken(path: String, bodyParams: [String: String]) async throws -> YNABTokenResponse {
        var request = URLRequest(url: URL(string: OAuthConfig.oauthRelayBaseURL + path)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: bodyParams)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw YNABTokenExchangeError.other }
        // The relay passes YNAB's own token-endpoint status through
        // unchanged; YNAB returns 400 for both a malformed request and an
        // expired/revoked/reused refresh token (standard OAuth
        // `invalid_grant`) — treated as the latter since that's the case
        // worth reacting to.
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

private enum YNABTokenExchangeError: Error {
    case invalidGrant
    case other
}

private struct YNABTokenResponse: Decodable {
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
