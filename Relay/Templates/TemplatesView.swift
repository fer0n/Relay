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

private let logger = Logger(subsystem: Const.loggerSubsystem, category: "TemplatesView")

struct TemplatesView: View {
    @State private var splitwiseAuth = SplitwiseAuthService()
    @State private var config = WalletTransactionConfigStore.load()
    @State private var pendingDeletion: String?

    /// The default Splitwise template ("Shared Expenses" unless renamed) —
    /// pinned to the top since it's where new merchants are auto-filed. Only
    /// when Splitwise is connected, matching when it actually behaves as the
    /// default (and when its "Default for new merchants" subtitle shows);
    /// otherwise it just sorts into the normal list like any other template.
    private var pinnedDefaultName: String? {
        guard splitwiseAuth.isAuthenticated else { return nil }
        return config.templates.first(where: { $0.value.isSplitwiseDefault })?.key
    }

    private var otherTemplateNames: [String] {
        config.templates.keys.filter { $0 != pinnedDefaultName }.sorted()
    }

    var body: some View {
        List {
            Section {
                NavigationLink {
                    CardsMappingView()
                } label: {
                    CardsMappingRow(cardCount: config.cards.count)
                }
            }
            .cardRowBackground()

            if let pinnedDefaultName {
                Section {
                    templateLink(name: pinnedDefaultName)
                }
                .cardRowBackground()
            }

            if !otherTemplateNames.isEmpty {
                Section {
                    ForEach(otherTemplateNames, id: \.self) { name in
                        templateLink(name: name)
                    }
                }
                .cardRowBackground()
            }
        }
        .themedList(background: .backgroundColor)
        .navigationTitle("Templates")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                NavigationLink {
                    TemplateEditView(templateName: nil, onSave: { _ in reload() }, onDelete: reload)
                } label: {
                    Image(systemName: Const.Symbol.add)
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

    @ViewBuilder
    private func templateLink(name: String) -> some View {
        NavigationLink {
            TemplateEditView(templateName: name, onSave: { _ in reload() }, onDelete: reload)
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

private struct CardsMappingRow: View {
    let cardCount: Int

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("Cards Mapping")
                // Pluralised through the string catalog (a "one"/"other"
                // variation per language), not with an inline "s" suffix:
                // that trick bakes English pluralisation into the format
                // string, leaving the translation a "%lld card%@" with a
                // stray placeholder no other language can use. `^[…](inflect:
                // true)` would be the tidier source, but Apple's automatic
                // grammatical agreement only covers a handful of languages
                // and silently falls back to the uninflected form elsewhere —
                // "2 Karte" — which isn't worth the two lines it saves.
                Text("\(cardCount) cards")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            ListChevron()
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
        var parts: [String] = []
        // Only meaningful once Splitwise is connected — it's the template new
        // Splitwise merchants get auto-filed under.
        if splitwiseConnected, template.isSplitwiseDefault {
            parts.append(String(localized: "Default"))
        }
        parts.append(String(localized: "\(template.autoMatch.count) rules"))
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
