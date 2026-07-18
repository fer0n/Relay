---
title: Relay Privacy Policy
---

# Privacy Policy for Relay

**Last updated:** July 15, 2026

Relay is a personal-finance utility that connects to your own YNAB and/or
Splitwise account to add transactions and import bank statement files.
Each installation only ever accesses the YNAB/Splitwise account you
connect it to — your tokens and data are never visible to, or shared
with, any other user of the app.

## Data we access

When you connect YNAB and/or Splitwise, Relay requests OAuth access to:

- Read your YNAB budget, categories, and accounts, and create transactions
  in YNAB on your behalf.
- Read your Splitwise groups and friends, and create expenses in Splitwise
  on your behalf.

Relay also processes bank/CSV statement files you choose to import, solely
to extract transaction data for import into YNAB.

## How data is handled and stored

- OAuth access tokens (and, where issued, refresh tokens) are stored only in
  the device's Keychain, protected by the operating system, and are used
  only to call YNAB's or Splitwise's own APIs directly over HTTPS.
- Signing in (and silently refreshing an expired token) passes through a
  small relay service Relay's developer runs on Cloudflare Workers, whose
  only job is to complete the OAuth token exchange with YNAB/Splitwise
  using a credential that can't safely be stored in the app itself. It
  does not store anything — it relays the exchange and forgets it — and it
  never sees your budget, transaction, or expense data, only the
  short-lived codes/tokens involved in signing in.
- Beyond that relay, Relay has no backend server. There is no database,
  analytics service, or third party that receives your financial data —
  data obtained through the YNAB API or the Splitwise API is not knowingly
  passed to any third party.
- Imported statement files are read locally on-device to build transactions
  for YNAB; Relay does not upload or retain copies of these files beyond
  what's needed to complete the import.
- If a transaction or expense can't be sent because the device is offline,
  Relay stores it in local on-device storage (amount, payee/description,
  category, and which friend it's split with) and retries automatically the
  next time the app is opened or a Shortcut runs. This "Pending Queue" is
  visible in the app, and never leaves the device or is sent anywhere other
  than YNAB's or Splitwise's own APIs once it syncs.
- The wallet automations' "Ensure Completion" option (on by default) briefly
  stores what that run was given (amount, merchant name, and — for YNAB —
  the card label) locally, and requests permission to send you a local
  notification if the run is interrupted before finishing — since there's
  no way for Relay to resume a Shortcuts run that was cut off partway
  through. That notification is generated and delivered entirely on-device;
  nothing about it is sent anywhere. Tapping it (or a matching entry in the
  app's "Transaction Drafts" screen) opens Relay to finish creating that
  transaction/expense using the same YNAB/Splitwise API calls as normal.
  The stored draft is deleted as soon as the transaction completes (or you
  dismiss it yourself).

## Retention

Tokens remain in the device Keychain until you disconnect an account in
Relay or delete the app, at which point they are removed. Relay does not
retain transaction or budget data outside of what YNAB and Splitwise
themselves store, other than the Pending Queue and Transaction Drafts
above, each of which is deleted as soon as it's resolved (synced,
completed, or removed by you).

## Deleting your data

- To remove Relay's access, disconnect YNAB and/or Splitwise from within the
  app (this deletes the local tokens), and/or revoke Relay's access from
  your YNAB or Splitwise account security settings.
- Deleting the app removes all locally stored tokens.

## Changes to this policy

If this policy changes in a way that affects how your data is used, you
will be asked to re-authorize before continuing to use the affected
integration. The "Last updated" date above reflects the most recent
revision.

## Contact

Questions about this policy, or data-deletion requests, can be filed as an
issue at https://github.com/fer0n/Relay/issues.

## Disclaimers

Relay is not affiliated, associated, or in any way officially connected
with YNAB or You Need A Budget, or with Splitwise, Inc., nor endorsed by
them.
