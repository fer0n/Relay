//
//  HazelShortcuts.swift
//  Hazel
//

import AppIntents

struct HazelShortcuts: AppShortcutsProvider {
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
    }
}
