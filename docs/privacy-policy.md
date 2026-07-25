---
title: Relay Privacy Policy
---

# Privacy Policy for Relay

**Last updated:** July 25, 2026

Relay is a personal-finance utility that connects to your own YNAB and/or
Splitwise account to add transactions and import bank statement files.
Each installation only ever accesses the YNAB/Splitwise account you
connect it to — your tokens and data are never visible to, or shared
with, any other user of the app.

## Data Relay accesses

When you connect YNAB and/or Splitwise, Relay requests OAuth access to:

- Read your YNAB budget, categories, and accounts, and create transactions
  in YNAB on your behalf.
- Read your Splitwise groups, friends, balances, shared expenses, and recent
  account activity, and create, delete, or restore expenses in Splitwise on
  your behalf.

Relay also processes bank/CSV statement files you choose to import, solely
to extract transaction data for import into YNAB.

## How data is handled and stored

- OAuth access tokens (and, where issued, refresh tokens) are stored only in
  the device's Keychain, protected by the operating system, and are used
  only to call YNAB's or Splitwise's own APIs directly over HTTPS.
- Signing in (and refreshing an expired token) passes through a small relay
  service whose only job is to complete the OAuth token exchange using a
  credential that can't safely live in the app. It stores nothing and never
  sees your budget, transaction, or expense data — only the short-lived
  sign-in codes/tokens. Relay has no other backend: no database, no
  analytics, no third party receives data obtained through the YNAB or
  Splitwise API.
- What Relay reads from YNAB and Splitwise to display in the app — your YNAB
  categories and accounts, and your Splitwise friends, balances, shared
  expense history, and recent account activity — is cached on-device so
  screens open instantly and still show something when you're offline. These
  caches only ever come from those APIs and go nowhere else; they're refreshed
  in place, and deleted when you disconnect the corresponding account.
- Imported statement files are read locally on-device to build transactions
  for YNAB; Relay does not upload or retain copies of these files beyond
  what's needed to complete the import.
- If a transaction or expense can't be sent because the device is offline,
  Relay stores it on-device (amount, payee/description, category, and which
  friend it's split with) and retries automatically the next time the app is
  opened or a Shortcut runs. This "Pending Queue" is visible in the app and
  goes nowhere but YNAB's or Splitwise's own APIs once it syncs.
- The wallet automations' "Ensure Completion" option (on by default) briefly
  stores what a run was given (amount, merchant name, and — for YNAB — the
  card label) on-device as a "Transaction Draft" so an interrupted run can
  be finished later, and may deliver an on-device local notification to
  remind you. This data and notification never leave the device, and the
  draft is deleted as soon as the transaction completes or you dismiss it.

## Retention

Tokens remain in the device Keychain until you disconnect an account in
Relay or delete the app, at which point they are removed. Relay does not
retain transaction or budget data outside of what YNAB and Splitwise
themselves store, other than the on-device caches, Pending Queue, and
Transaction Drafts above. The Pending Queue and Transaction Drafts are
deleted as soon as they're resolved (synced, completed, or removed by the
user); the caches are deleted when you disconnect that account.

## Deleting your data

- To remove Relay's access, disconnect YNAB and/or Splitwise from within the
  app (this deletes the local tokens and that account's cached data), and/or
  revoke Relay's access from your YNAB or Splitwise account security settings.
- Deleting the app removes all locally stored tokens and cached data.

## Changes to this policy

Any changes to this policy will be published here, with the "Last updated"
date above revised to reflect the most recent revision.

## Contact

Questions about this policy, or data-deletion requests, can be filed as an
issue at https://github.com/fer0n/Relay/issues.

## Disclaimers

Relay is not affiliated, associated, or in any way officially connected
with YNAB or You Need A Budget, or with Splitwise, Inc., nor endorsed by
them.
