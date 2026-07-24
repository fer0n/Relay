//
//  CardsMappingView.swift
//  Relay
//
//  In-app editor for WalletTransactionConfig.cards — the card→YNAB-account
//  mappings the wallet intents otherwise build up interactively (a card is
//  remembered the first time it's used so recurring cards don't need
//  re-asking). Reads/writes the same WalletTransactionConfigStore JSON file
//  the intents and TemplateEditView mutate, and mirrors TemplateEditView's
//  name + account-picker layout so it sits naturally in the Templates list.
//

import SwiftUI
import os

private let logger = Logger(subsystem: "com.octabits.relay", category: "CardsMappingView")

struct CardsMappingView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var ynabAuth = YNABAuthService()

    @State private var accounts: [YNABAccount] = []
    @State private var isLoadingAccounts = false

    /// card name → YNAB account id, edited locally and persisted on Save.
    @State private var mappings: [String: String]
    @State private var errorMessage: String?

    /// Snapshot of the loaded mappings, compared against `mappings` in
    /// `hasChanges` so the Save bar only appears once something's changed.
    private let originalMappings: [String: String]

    init() {
        let cards = WalletTransactionConfigStore.load().cards
        _mappings = State(initialValue: cards)
        originalMappings = cards
    }

    private var sortedCards: [String] {
        mappings.keys.sorted()
    }

    private var hasChanges: Bool {
        mappings != originalMappings
    }

    var body: some View {
        List {
            if sortedCards.isEmpty {
                Section {
                    Text("No cards yet. A card is remembered the first time you add a wallet transaction with it, then appears here to remap.")
                        .footerText()
                }
                .listRowBackground(Color.backgroundColor)
            } else {
                Section {
                    ForEach(sortedCards, id: \.self) { card in
                        DraftDetailRow(
                            icon: "creditcard.fill",
                            title: "\(card)",
                            isIncomplete: mappings[card] == nil
                        ) {
                            if isLoadingAccounts, accounts.isEmpty {
                                ProgressView()
                            } else {
                                MenuPickerField(
                                    selection: binding(for: card),
                                    label: accounts.first { $0.id == mappings[card] }?.name ?? "Select account"
                                ) {
                                    ForEach(accounts, id: \.id) { account in
                                        Text(account.name).tag(Optional(account.id))
                                    }
                                }
                            }
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) {
                                mappings.removeValue(forKey: card)
                            }
                        }
                    }
                }
                .cardRowBackground()
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
                .listRowBackground(Color.backgroundColor)
            }
        }
        .themedList(background: .backgroundColor)
        .navigationTitle("Cards Mapping")
        .bottomBarActionButton(isPresented: hasChanges, title: "Save", action: save)
        .task {
            await loadAccounts()
        }
    }

    private func binding(for card: String) -> Binding<String?> {
        Binding(
            get: { mappings[card] },
            set: { newValue in
                if let newValue {
                    mappings[card] = newValue
                } else {
                    mappings.removeValue(forKey: card)
                }
            }
        )
    }

    private func loadAccounts() async {
        guard ynabAuth.isAuthenticated, let token = await YNABAuthService.validAccessToken() else { return }
        if let cached = YNABAccountCacheStore.load() {
            accounts = cached
        }
        isLoadingAccounts = accounts.isEmpty
        defer { isLoadingAccounts = false }
        do {
            accounts = try await YNABAccountCacheStore.fetch(token: token)
        } catch {
            logger.error("failed to load accounts: \(String(describing: error), privacy: .public)")
            if accounts.isEmpty {
                errorMessage = "Failed to load accounts: \(error.localizedDescription)"
            }
        }
    }

    private func save() {
        var config = WalletTransactionConfigStore.load()
        config.cards = mappings
        do {
            try WalletTransactionConfigStore.save(config)
            logger.log("saved \(mappings.count, privacy: .public) card mappings")
            dismiss()
        } catch {
            logger.error("failed to save card mappings: \(String(describing: error), privacy: .public)")
            errorMessage = "Failed to save: \(error.localizedDescription)"
        }
    }
}

#Preview {
    NavigationStack {
        CardsMappingView()
    }
}
