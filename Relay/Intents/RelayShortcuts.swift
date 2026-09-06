//
//  RelayShortcuts.swift
//  Relay
//

import AppIntents

struct RelayShortcuts: AppShortcutsProvider {
    // The icon names below stay inline literals rather than `Const.Symbol`
    // references: `AppShortcut.systemImageName` is compile-time evaluated by
    // AppIntents and rejects anything that isn't a literal.
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddYNABTransactionIntent(),
            phrases: [
                "Add a transaction in \(.applicationName)",
                "Add a YNAB transaction in \(.applicationName)",
                "Add an expense in \(.applicationName)",
            ],
            shortTitle: "Add Transaction",
            systemImageName: "plus.circle"
        )
        AppShortcut(
            intent: AddLedgerExpenseIntent(),
            phrases: [
                "Add a shared expense in \(.applicationName)",
                "Split an expense in \(.applicationName)",
            ],
            shortTitle: "Add Shared Expense",
            systemImageName: "person.2.circle"
        )
        AppShortcut(
            intent: ImportYNABFileIntent(),
            phrases: [
                "Import a file to \(.applicationName)",
                "Import a statement to \(.applicationName)",
            ],
            shortTitle: "Import File",
            systemImageName: "doc.badge.plus"
        )
        AppShortcut(
            intent: ImportLedgerFileIntent(),
            phrases: [
                "Import a file to split in \(.applicationName)",
                "Import a statement to split in \(.applicationName)",
            ],
            shortTitle: "Import File to Split",
            systemImageName: "doc.badge.plus"
        )
        // ImportTemplateFileIntent is intentionally *not* promoted as an App
        // Shortcut: it's no longer a user-facing feature (Settings exports a
        // full backup now, not a template file), but the intent itself stays
        // defined because the "YNAB Toolkit → Relay Migration" Shortcut
        // invokes its "Import Template File" action. Dropping it from here
        // hides the suggestion without removing the action that migration
        // depends on.
    }
}
