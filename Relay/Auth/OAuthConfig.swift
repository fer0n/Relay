//
//  OAuthConfig.swift
//  Relay
//

enum OAuthConfig {
    static let callbackScheme = "relay"
    static let ynabRedirectURI = "relay://oauth/ynab"
    static let splitwiseRedirectURI = "relay://oauth/splitwise"

    /// The relay-auth Cloudflare Worker (see ../../oauth-relay/README.md)
    /// that holds YNAB's/Splitwise's client_secret so the app doesn't have
    /// to — required for distributing the app beyond a single device.
    static let oauthRelayBaseURL = "https://relay-auth.octabits.net"

    /// A Client ID is a public identifier, not a credential — it's sent in
    /// the clear as part of every authorization URL, so unlike a client
    /// secret there's no reason to keep it out of source control. Registered
    /// at https://app.ynab.com/settings/developer.
    static let ynabClientID = "H9rs04UxQwwoNYSvQ7iey_sHKeJycm-ulLqPvEoRf4Y"

    /// Same as `ynabClientID` above — registered at
    /// https://secure.splitwise.com/apps.
    static let splitwiseClientID = "HxoenkRXpGHl5imUcv3ajZU9safLo6ZlmTADfKlX"
}
