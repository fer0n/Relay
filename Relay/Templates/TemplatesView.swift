//
//  TemplatesView.swift
//  Relay
//
//  In-app viewer/editor for the merchant templates that
//  AddWalletTransactionToYNABIntent / AddWalletTransactionToSplitwiseIntent
//  otherwise only build up interactively via Shortcuts prompts. Reads/writes
//  the same WalletTransactionConfigStore JSON file both intents mutate — one
//  template now carries both a YNAB category and a Splitwise split
//  option/friend, so the same bucket works for either automation.
//

import AppIntents
import SwiftUI
import os

private let logger = Logger(subsystem: "com.octabits.relay", category: "TemplatesView")

struct TemplatesView: View {
    @State private var splitwiseAuth = SplitwiseAuthService()
    @State private var config = WalletTransactionConfigStore.load()
    @State private var pendingDeletion: String?

    var body: some View {
        List {
            Section {
                ForEach(config.templates.keys.sorted(), id: \.self) { name in
                    NavigationLink {
                        TemplateEditView(templateName: name, onSave: reload, onDelete: reload)
                    } label: {
                        TemplateRow(
                            name: name,
                            template: config.templates[name] ?? WalletTransactionConfig.Template(),
                            splitwiseConnected: splitwiseAuth.isAuthenticated
                        )
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) {
                            pendingDeletion = name
                        }
                    }
                }
            }
            .cardRowBackground()
        }
        .themedList(background: .backgroundColor)
        .navigationTitle("Templates")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                NavigationLink {
                    TemplateEditView(templateName: nil, onSave: reload, onDelete: reload)
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .onAppear(perform: reload)
        .confirmationDialog(
            "Delete \"\(pendingDeletion ?? "")\"?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let pendingDeletion {
                    deleteTemplate(pendingDeletion)
                }
                pendingDeletion = nil
            }
        }
    }

    private func reload() {
        config = WalletTransactionConfigStore.load()
    }

    private func deleteTemplate(_ name: String) {
        var config = WalletTransactionConfigStore.load()
        config.templates.removeValue(forKey: name)
        config.merchants = config.merchants.filter { $0.value.templateName != name }
        do {
            try WalletTransactionConfigStore.save(config)
            logger.log("deleted template \(name, privacy: .public)")
            reload()
        } catch {
            logger.error("failed to delete template: \(String(describing: error), privacy: .public)")
        }
    }
}

private struct TemplateRow: View {
    let name: String
    let template: WalletTransactionConfig.Template
    let splitwiseConnected: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(name)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            ListChevron()
        }
    }

    private var subtitle: String {
        var parts = ["\(template.autoMatch.count) auto-match rule\(template.autoMatch.count == 1 ? "" : "s")"]
        if splitwiseConnected, template.splitwiseOption != .never {
            parts.append(template.splitwiseOption.label)
        }
        return parts.joined(separator: " · ")
    }
}

extension SplitwiseTemplateOption {
    /// Plain-text label for use in Relay's own SwiftUI screens, derived
    /// from `caseDisplayRepresentations` (the Shortcuts/Siri-facing
    /// strings) so the wording is only defined in one place.
    var label: String {
        String(localized: Self.caseDisplayRepresentations[self]?.title ?? "")
    }
}

#Preview {
    NavigationStack {
        TemplatesView()
    }
}
