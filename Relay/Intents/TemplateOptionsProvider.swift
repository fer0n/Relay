//
//  TemplateOptionsProvider.swift
//  Relay
//
//  "Which merchant template" picker for AddWalletTransactionToYNABIntent's
//  Template parameter — the one setup question that's still worth asking
//  through a Shortcuts prompt. Lives in its own file because both wallet
//  intents build up the same WalletTransactionConfigStore templates, so the
//  options list and its sentinel belong to neither in particular.
//

import AppIntents

/// Sentinel option meaning "not from here": the automation parks the purchase
/// as a draft and the template is picked or created in Relay's own form
/// instead (see AddWalletTransactionToYNABIntent). Any parameter value that
/// doesn't name a real template takes the same path — including the old
/// "Create New Template" sentinel still stored in an existing automation, so
/// nothing needs migrating.
nonisolated let setUpInRelayOption = String(localized: "Set Up in Relay")

nonisolated struct TemplateOptionsProvider: DynamicOptionsProvider {
    func results() async throws -> [String] {
        let config = WalletTransactionConfigStore.load()
        return [setUpInRelayOption] + config.templates.keys.sorted()
    }
}
