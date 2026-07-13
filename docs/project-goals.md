# Hazel — Project Goals

## Why

Today, adding transactions to YNAB and Splitwise, and importing bank statement
files into YNAB, happens through a set of Apple Shortcuts. That setup works
but is cumbersome to maintain and edit. Hazel is a native SwiftUI app
(iOS/macOS/visionOS) meant to replace that Shortcuts-based workflow with a
proper app while keeping it triggerable the same way (Shortcuts/Siri/widgets)
via App Intents.

## Target features

1. **Authentication**
   - Sign in with YNAB (OAuth2)
   - Sign in with Splitwise (OAuth2)
2. **Add transactions** (exposed as App Intents, usable from Shortcuts/Siri/
   widgets, and as in-app quick-entry)
   - Add a transaction to YNAB
   - Add an expense to Splitwise
3. **File import**
   - Share-sheet / file import flow for bank/CSV statement files into YNAB

## Source of truth: existing Shortcuts

These are the current Shortcuts being replaced. They're the reference for
required API calls, field mappings, and edge cases during conversion —
inspect each one (open the link, or `Add Shortcut` then export/view actions)
before implementing the equivalent feature.

| Shortcut | Purpose | Link |
|---|---|---|
| Transaction → YNAB | Triggered by a Wallet transaction; hands the transaction off to YNAB Toolkit | https://www.icloud.com/shortcuts/6a4d5c58e2d24ffab2deee95f16273cd |
| YNAB Toolkit | Core YNAB logic — file import, adding transactions, etc. Called by other shortcuts | https://www.icloud.com/shortcuts/9f63c5965c644adcbc7a2d047fb32c5d |
| YNAB File Import | Share-sheet action that imports a file into YNAB | https://www.icloud.com/shortcuts/17b4759eea6a4f2e8bf7bc8cd60bbe8f |
| Add YNAB Expense | Adds one manual transaction; duplicated per recurring/individual transaction | https://www.icloud.com/shortcuts/729de384556a484399a2dd95789f7d59 |
| Splitwise Master | Core Splitwise logic — adding expenses, etc. | https://www.icloud.com/shortcuts/bd9aa0c310c74c9398b9ae81e3a3c6c5 |

## Status

- [ ] Inspect each Shortcut's actions (auth flow, API endpoints, field mappings)
- [ ] Design App Intents + auth architecture
- [ ] Implement YNAB auth
- [ ] Implement Splitwise auth
- [x] Implement "Add YNAB transaction" intent
- [ ] Implement "Add Splitwise expense" intent
- [ ] Implement YNAB file import flow
