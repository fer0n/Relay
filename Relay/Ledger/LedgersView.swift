//
//  LedgersView.swift
//  Relay
//
//  The ledgers, as a stack of full-width balance cards.
//
//  One card per row, not the 2-up grid this started as: two cards side by side
//  meant a LazyVGrid inside one row, and List expects one tap target per row —
//  the NavigationLinks misfired into each other.
//

import CloudKit
import SwiftUI

struct LedgersView: View {
    @State private var store = LedgerStore.shared
    @State private var newLedgerName = ""
    @State private var isNaming = false
    @State private var renaming: Ledger?

    var body: some View {
        List {
            if !store.isAvailable {
                unavailableSection
            } else {
                if store.ledgers.isEmpty {
                    Section {
                        Text("A ledger is a shared expense list that lives in your iCloud. Create one, then invite whoever you're splitting with.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .cardRowBackground()
                }

                Section {
                    ForEach(store.ledgers) { ledger in
                        NavigationLink(value: ContentRoute.ledger(zoneName: ledger.zoneName)) {
                            LedgerBalanceCard(
                                ledger: ledger,
                                balances: store.balances(in: ledger),
                                currentUserID: ledger.currentUserID,
                                maxWidth: .infinity
                            )
                        }
                        .buttonStyle(.plain)
                        .transition(.contentRow)
                        .contextMenu {
                            Button {
                                renaming = ledger
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            Button(ledger.isOwnedByCurrentUser ? "Delete" : "Leave", role: .destructive) {
                                Task { await store.remove(ledger) }
                            }
                        }
                    }
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.backgroundColor)

                Section {
                    Button {
                        newLedgerName = ""
                        isNaming = true
                    } label: {
                        Label("New Ledger", systemImage: Const.Symbol.add)
                    }
                }
                .cardRowBackground()
            }

            if let lastError = store.lastError {
                Section {
                    Text(lastError)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .cardRowBackground()
            }
        }
        .themedList(background: .backgroundColor)
        .navigationTitle("Ledgers")
        .task {
            await store.refresh(force: false)
            // Only once someone else can write to a ledger — the first
            // moment a notification would have anything to say.
            if !store.sharedLedgers.isEmpty {
                await LedgerChangeNotifier.requestAuthorizationIfNeeded()
            }
        }
        .refreshable { await store.refresh(force: true) }
        .ledgerRenameAlert($renaming)
        .alert("New Ledger", isPresented: $isNaming) {
            TextField("Name", text: $newLedgerName)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                let name = newLedgerName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                Task { await store.createLedger(name: name) }
            }
        } message: {
            Text("Household, Trip to Lisbon — whatever you're splitting.")
        }
    }

    /// Signing out isn't an error, so `store.lastError` stays nil for it.
    private var unavailableSection: some View {
        Section {
            Label("iCloud Unavailable", systemImage: "icloud.slash")
            Text(unavailableExplanation)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .cardRowBackground()
    }

    private var unavailableExplanation: String {
        switch store.accountStatus {
        case .noAccount:
            return String(localized: "Sign in to iCloud in Settings to use ledgers. Nothing leaves your iCloud account.")
        case .restricted:
            return String(localized: "iCloud is restricted on this device, so ledgers aren't available.")
        default:
            return String(localized: "Relay couldn't reach iCloud. Pull to try again.")
        }
    }
}
