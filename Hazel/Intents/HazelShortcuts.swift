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
    }
}
