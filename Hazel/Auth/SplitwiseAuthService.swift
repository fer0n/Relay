//
//  SplitwiseAuthService.swift
//  Hazel
//
//  Splitwise only offers the authorization code grant, which requires a
//  client secret for the token exchange. Since Hazel is a personal,
//  non-distributed app, the secret lives in the gitignored Secrets.swift
//  rather than a backend.
//

import AuthenticationServices
import Foundation
import Observation

@MainActor
@Observable
final class SplitwiseAuthService {
    private(set) var accessToken: String?
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

    func signIn() {
        var components = URLComponents(string: "https://secure.splitwise.com/oauth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: Secrets.splitwiseClientID),
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

        var request = URLRequest(url: URL(string: "https://secure.splitwise.com/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let bodyParams = [
            "client_id": Secrets.splitwiseClientID,
            "client_secret": Secrets.splitwiseClientSecret,
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": OAuthConfig.splitwiseRedirectURI,
        ]
        request.httpBody = bodyParams
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let token = try JSONDecoder().decode(SplitwiseTokenResponse.self, from: data)
            accessToken = token.accessToken
            KeychainStore.save(token.accessToken, for: Self.accessTokenKey)
            if let refreshToken = token.refreshToken {
                KeychainStore.save(refreshToken, for: Self.refreshTokenKey)
            }
        } catch {
            print("Splitwise token exchange failed: \(error)")
        }
    }

    func signOut() {
        accessToken = nil
        KeychainStore.delete(for: Self.accessTokenKey)
        KeychainStore.delete(for: Self.refreshTokenKey)
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
