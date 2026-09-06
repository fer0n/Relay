---
title: Relay Privacy Policy
---

# Privacy Policy for Relay

**Last updated:** September 6, 2026

Relay is a personal-finance utility that connects to your own YNAB account
to add transactions and import bank statement files, and keeps shared
expense lists ("ledgers") in your own iCloud. Each installation only ever
accesses the YNAB account you connect it to — your token and data are
never visible to, or shared with, any other user of the app.

## Data Relay accesses

When you connect YNAB, Relay requests OAuth access to:

- Read your YNAB budget, categories, and accounts, and create transactions
  in YNAB on your behalf.

Relay no longer connects to Splitwise. A previous version did; upgrading
deletes its stored tokens and everything cached from its API.

Relay also processes bank/CSV statement files you choose to import, solely
to extract transaction data for import into YNAB.

## How data is handled and stored

- OAuth access tokens (and, where issued, refresh tokens) are stored only in
  the device's Keychain, protected by the operating system, and are used
  only to call YNAB's own API directly over HTTPS.
- Signing in (and refreshing an expired token) passes through a small relay
  service whose only job is to complete the OAuth token exchange using a
  credential that can't safely live in the app. It stores nothing and never
  sees your budget or transaction data — only the short-lived sign-in
  codes/tokens. Relay has no other backend: no database, no analytics, no
  third party receives data obtained through the YNAB API.
- What Relay reads from YNAB to display in the app — your categories and
  accounts — is cached on-device so screens open instantly and still show
  something when you're offline. That cache only ever comes from YNAB's API
  and goes nowhere else; it's refreshed in place, and deleted when you
  disconnect the account.
- Imported statement files are read locally on-device to build transactions
  for YNAB; Relay does not upload or retain copies of these files beyond
  what's needed to complete the import.
- If a transaction or expense can't be sent because the device is offline,
  Relay stores it on-device and retries automatically the next time the app
  is opened or a Shortcut runs — for a YNAB transaction the amount, payee
  and category; for a ledger expense the description, amount, date and each
  participant's share and name. A queued ledger expense also shows on its
  ledger straight away, marked as still waiting. This "Pending Queue" is
  visible in the app, and once it syncs an entry goes nowhere but the
  service it was always headed for: YNAB's own API, or your iCloud.
- The wallet automations' "Ensure Completion" option (on by default) briefly
  stores what a run was given (amount, merchant name, and — for YNAB — the
  card label) on-device as a "Transaction Draft" so an interrupted run can
  be finished later, and may deliver an on-device local notification to
  remind you. This data and notification never leave the device, and the
  draft is deleted as soon as the transaction completes or you dismiss it.

## Ledgers (iCloud)

Relay keeps shared expense lists ("ledgers") in your own iCloud account.
These require no account and no sign-in beyond the iCloud account
already on your device.

- A ledger's contents — its name and settings, and each expense's
  description, amount, currency, date, and who paid and owes what — are
  stored in Relay's private CloudKit database inside **your** iCloud
  account. They are not sent to Relay's developer, to YNAB, or to any other
  third party, and no server operated for Relay can read them.
- When you invite someone to a ledger, iCloud shares that ledger's data with
  the people you invite, and they can add and edit expenses on it. Everyone
  on a ledger can see every expense on it, and the names iCloud shows for the
  other participants come from Apple's sharing system, not from Relay.
  Inviting someone is always an explicit action you take.
- You can also set a name and a photo for yourself — or for anyone else — on
  a ledger. These are stored on the ledger itself, alongside its expenses, and
  so are visible to everyone on that ledger and editable by them. They are
  stored nowhere else: a photo you pick is downscaled on your device and
  written straight to the ledger in iCloud, and both are deleted with the
  ledger. Setting them is optional; leaving them unset means iCloud's own
  name for you is shown, where it has one.
- Balances and settle-up suggestions are computed on your device from the
  expenses above; nothing about them is sent anywhere.
- If you allow notifications, Relay subscribes to iCloud for a silent
  signal that a ledger changed, and then tells you on-device what was added.
  The notification is composed on your device from data already in your
  iCloud; its text is not sent to Apple or anyone else, and the signal
  itself carries no expense details.
- Data in a ledger is subject to Apple's iCloud terms and privacy policy for
  as long as it's stored there.
- Deleting a ledger you own removes it and its expenses from iCloud for
  everyone on it. Leaving a ledger someone else owns removes your access
  without deleting their copy. Deleting the app leaves ledgers in iCloud;
  remove them in the app first if you want them gone.

## Backups (iCloud Drive)

Relay writes a daily backup into its own folder in your iCloud Drive
("Relay ▸ Backups"), and one whenever you tap "Back Up Now".

- Each backup is a JSON file holding your templates, auto-match rules,
  merchants, cards, import settings and preferences, plus a copy of your
  ledgers and their expenses, with totals and a checksum so the file can be
  checked against your live data.
- Backups never contain OAuth access tokens or any login credentials.
- The files are stored in your own iCloud Drive, under your Apple Account.
  Nothing is uploaded to Relay or to any third party.
- Older backups are thinned out automatically: everything from the last
  week is kept, then one per week for six months, one per month for a year,
  and one per half-year beyond that. Backups you make yourself are kept
  until you delete them.
- You can turn backups off in Settings, and delete the files at any time in
  the Files app.

## Retention

Your YNAB token remains in the device Keychain until you disconnect the
account in Relay or delete the app, at which point it is removed. Relay
does not retain transaction or budget data outside of what YNAB itself
stores, what your ledgers hold in your iCloud, and the iCloud Drive backups
above, other than the on-device caches, Pending Queue, and Transaction
Drafts above. The Pending Queue and Transaction Drafts are
deleted as soon as they're resolved (synced, completed, or removed by the
user); the caches are deleted when you disconnect that account.

## Deleting your data

- To remove Relay's access, disconnect YNAB from within the app (this deletes
  the local token and that account's cached data), and/or revoke Relay's
  access from your YNAB account security settings.
- Deleting the app removes all locally stored tokens and cached data. It
  does not remove the backups in your iCloud Drive; delete the "Relay"
  folder in the Files app if you want those gone too.
- To remove a ledger's data, delete the ledger in the app (if you own it) or
  leave it (if you don't). You can also remove Relay's iCloud data entirely
  from iOS Settings → your name → iCloud → Manage Account Storage.

## Changes to this policy

Any changes to this policy will be published here, with the "Last updated"
date above revised to reflect the most recent revision.

## Contact

Questions about this policy, or data-deletion requests, can be filed as an
issue at https://github.com/fer0n/Relay/issues.

## Disclaimers

Relay is not affiliated, associated, or in any way officially connected
with YNAB or You Need A Budget, nor endorsed by them.
