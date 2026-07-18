# Relay

Personal app replacing an Apple Shortcuts workflow: authenticate with YNAB
and Splitwise, add transactions to both, and import bank/CSV statement
files into YNAB. See [docs/project-goals.md](docs/project-goals.md).

## YNAB API Terms of Service — constraints on this codebase

Source: https://api.ynab.com/#terms — re-check this page if anything below
seems out of date before relying on it.

- **Token handling**: access tokens must never be logged, exposed to a
  third party, or sent anywhere except YNAB's own API. Store only in
  Keychain (see `Relay/Auth/KeychainStore.swift`). Never request or store
  the user's actual YNAB/bank login credentials — only OAuth tokens.
- **Rate limit**: each access token is capped at **200 requests/hour**
  (rolling window); exceeding it returns HTTP 429. Any code that calls the
  YNAB API in bulk (e.g. file import creating many transactions) must
  batch/throttle and handle 429 with backoff rather than hammering retries.
- **No third-party sharing**: data pulled from the YNAB API must not be
  passed to any third party (analytics SDKs, crash reporters that capture
  request bodies, etc.) without updating the privacy policy and
  re-prompting consent first.
- **No undocumented endpoints**: only call documented YNAB API endpoints.
- **Required attribution**: the app must display, somewhere a user will
  see it (e.g. an About/Settings screen — not just the privacy policy),
  the disclaimer: "We are not affiliated, associated, or in any way
  officially connected with YNAB or any of its subsidiaries or
  affiliates." Implemented as a footer in ContentView.swift.
- **Naming/branding**: never name the app or a feature "YNAB ___"; "___
  for YNAB" is fine. Don't alter YNAB's logo/branding.
- **Privacy policy must stay accurate**: [docs/privacy-policy.md](docs/privacy-policy.md)
  describes exactly how tokens/data are stored and deleted today. If token
  storage, retention, or third-party usage changes, update that file (and
  bump "Last updated") before shipping the change.

## Splitwise API Terms of Service — constraints on this codebase

Source: https://dev.splitwise.com/ — re-check this page if anything below
seems out of date before relying on it.

- **Token handling**: same rule as YNAB — access tokens only ever go in the
  Authorization header to Splitwise's own API, stored only in Keychain (see
  `Relay/Auth/KeychainStore.swift`), never logged, never sent to a third
  party. Never request or store the user's actual Splitwise login
  credentials — only OAuth tokens.
- **Rate limit**: no fixed number is published; Splitwise says usage is
  "subject to usage limits and other functional restrictions" at its
  discretion and may suspend access if abused. Since there's no documented
  threshold, code that calls the Splitwise API in bulk should still
  throttle conservatively and handle 429 with backoff rather than
  hammering retries (matches the YNAB approach).
- **No third-party sharing**: data pulled from the Splitwise API must not
  be passed to any third party without updating the privacy policy and
  re-prompting consent first.
- **No undocumented endpoints**: only call documented Splitwise API
  endpoints.
- **Data deletion**: delete a user's Splitwise data promptly on request —
  `SplitwiseAuthService.signOut()` already clears the Keychain tokens.
- **Naming/branding**: don't use Splitwise's name to endorse/promote this
  app, and don't use Splitwise's marks in the app's name, UI, or branding
  without permission. Never name the app or a feature "Splitwise ___"; "___
  for Splitwise" is fine.
- **No competing/replicating functionality**: don't build features whose
  purpose is to replicate or compete with Splitwise's own product.
- **Privacy policy must stay accurate**: [docs/privacy-policy.md](docs/privacy-policy.md)
  describes exactly how tokens/data are stored and deleted today. If token
  storage, retention, or third-party usage changes, update that file (and
  bump "Last updated") before shipping the change.
