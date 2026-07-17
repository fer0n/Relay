//
//  TemplateOptionsProvider.swift
//  Hazel
//
//  Shared "which merchant template" picker for both
//  AddWalletTransactionToYNABIntent and AddWalletTransactionToSplitwiseIntent
//  — the two intents build up the same WalletTransactionConfigStore
//  templates, so they share one options list and "create new" sentinel.
//

import AppIntents

let createNewTemplateOption = "Create New Template"

nonisolated struct TemplateOptionsProvider: DynamicOptionsProvider {
    func results() async throws -> [String] {
        let config = WalletTransactionConfigStore.load()
        return [createNewTemplateOption] + config.templates.keys.sorted()
    }
}
