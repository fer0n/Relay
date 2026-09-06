# Relay

Personal app replacing an Apple Shortcuts workflow: authenticate with YNAB,
add transactions to YNAB and to shared iCloud "ledgers", and import
bank/CSV statement files. See [docs/project-goals.md](docs/project-goals.md).

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

## iCloud / CloudKit — constraints on this codebase

Splitwise was removed (it now gates its API behind a Pro subscription);
splitting runs entirely on CloudKit. See `Relay/Ledger/` and `Relay/Split/`.

- **No credentials to handle**: a ledger needs no OAuth token and no account.
  The only identity involved is the device's iCloud account, which Relay never
  sees a credential for — `CKShare` participants are identified by an opaque
  per-container user record name.
- **Data stays in the user's own container**: everything a ledger holds lives
  in `iCloud.com.octabits.relay`, in the user's private database or in a zone
  they've shared. It must never be copied to a third party, and no server
  operated for Relay can read it.
- **Sharing is always explicit**: a ledger only becomes visible to someone else
  through Apple's own share sheet, initiated by the user. Never create or
  modify a `CKShare` outside that flow.
- **Zone-wide shares, not record hierarchies**: one zone per ledger, shared as
  a unit, so a participant with write access can add their own expenses. Don't
  reintroduce a root-record hierarchy — only the root's owner could restructure
  it.
- **Never key anything by CloudKit's `__defaultOwner__`**: CloudKit describes
  the *reader* to themselves with that placeholder everywhere it names a user
  — `CKShare.Participant.userIdentity`, `CKShare.currentUserParticipant`, a
  record's `creatorUserRecordID`, a zone's owner name. It means "me", so it
  means a different person on every device, and an expense keyed by it bills
  whoever opens it. `CKContainer.userRecordID()` is the stable id, and it's
  the same string other participants see that person by. Everything read out
  of CloudKit goes through `LedgerRecords.resolving(_:as:)` first.
- **Participant names are asymmetric**: `nameComponents` is filled in only for
  people the reader may discover, so A can see B's name while B sees nothing
  for A. Don't treat a missing name as an error, and don't route around it —
  `LedgerProfile` is the fix: names and photos live in the shared zone, where
  anyone on the ledger can set them for anyone.
- **Reads go through `recordZoneChanges`, not `CKQuery`**: queries need
  queryable indexes configured in the CloudKit schema and are only eventually
  consistent. Changes need neither and hand back a token.
- **Schema is append-only in production**: CloudKit record-type fields can't be
  renamed or removed once deployed, so treat `LedgerRecords`' field names as
  frozen and make every read tolerant of a missing one. Deploy the schema to
  production (CloudKit Console) before shipping a build that writes a new field.
- **Offline writes queue in Relay, not in CloudKit**: `CKDatabase.modifyRecords`
  isn't long-lived — with no network it fails outright with
  `CKError.networkUnavailable` (CKErrorDomain 3) and nothing holds it for
  later. `LedgerStore.save` keeps its optimistic row, hands the write to
  `PendingOperationQueue` and reports `.queued`; the queue retries on
  foreground and at the start of every intent, and `LedgerStore` folds
  anything still queued back into each refresh so it doesn't blink out. Every
  new ledger write path must go through `LedgerStore.save` to inherit that,
  and `Error.isConnectivityFailure` is what decides queue-vs-surface — keep
  CloudKit's own codes in it.
- **Balances are derived, never stored**: no server validates that an expense's
  shares total its cost, so `LedgerExpense.isBalanced` is checked before every
  write. Don't add a write path that skips it.
- **Privacy policy must stay accurate**: [docs/privacy-policy.md](docs/privacy-policy.md)
  describes what a ledger stores and who can see it. If that changes, update
  that file (and bump "Last updated") before shipping the change.
