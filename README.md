<p align="center">
  <img width="160" height="160" src="./docs/assets/Icon.png" alt="Relay logo">
</p>

<h1 align="center">Relay</h1>

<p align="center">
  Add transactions to YNAB & Splitwise via Shortcuts & Wallet automation, and import bank statements into YNAB
</p>

## Relay

## KEY FEATURES

### Add a transaction to YNAB

Quick-entry in the app, or hands-free from a Shortcut, Siri, or a widget.

### Add an expense to Splitwise

Split an expense with your default friends in a tap, or automate it from a Wallet transaction.

### File import

Send a bank or CSV statement to Relay from the share sheet and import it straight into YNAB.

### Runs from anywhere

Every action is exposed as an App Intent, so you can wire it into Shortcuts, Siri, and widgets.

## Setup

This app authenticates with YNAB and Splitwise over OAuth2. To build it you need to register your own OAuth applications and supply their client credentials, along with the small `oauth-relay` service used to complete the OAuth redirect flow (see the [`oauth-relay`](./oauth-relay) directory).

## Authentication

Relay signs in to both providers with OAuth2:

- The app runs the browser-based sign-in itself (`ASWebAuthenticationSession`) and receives an authorization `code`.
- It exchanges that code (and later refreshes tokens) through the [`oauth-relay`](./oauth-relay) Cloudflare Worker rather than calling the providers directly. The Worker holds each provider's `client_secret`, so the secret never ships inside the app.
- Only the resulting access/refresh tokens are stored, and only in the **Keychain** (`Relay/Auth/KeychainStore.swift`). Tokens are never logged, never persisted elsewhere, and never sent to any third party — only to each provider's own API.
- Relay never asks for or stores your actual YNAB/Splitwise/bank login credentials — only OAuth tokens.

Signing out (`SplitwiseAuthService.signOut()` / the YNAB equivalent) clears the tokens from the Keychain.

## Attribution

We are not affiliated, associated, or in any way officially connected with YNAB or any of its subsidiaries or affiliates. The official YNAB website can be found at https://www.ynab.com.

The names YNAB and You Need A Budget, as well as related names, tradenames, marks, trademarks, emblems, and images are registered trademarks of YNAB.

Relay is likewise not affiliated with, sponsored by, or endorsed by Splitwise, Inc.

- [YNAB API](https://api.ynab.com/)
- [Splitwise API](https://dev.splitwise.com/)

## Privacy

See the [privacy policy](./docs/privacy-policy.md).
