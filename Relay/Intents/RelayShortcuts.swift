//
//  RelayShortcuts.swift
//  Relay
//

import AppIntents

struct RelayShortcuts: AppShortcutsProvider {
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
            intent: AddSplitwiseExpenseIntent(),
            phrases: [
                "Add a Splitwise expense in \(.applicationName)",
                "Split an expense in \(.applicationName)",
            ],
            shortTitle: "Add Splitwise Expense",
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
            intent: ImportSplitwiseFileIntent(),
            phrases: [
                "Import a file to Splitwise in \(.applicationName)",
                "Import a statement to Splitwise in \(.applicationName)",
            ],
            shortTitle: "Import File to Splitwise",
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
