//
//  TemplatesView.swift
//  Hazel
//
//  In-app viewer/editor for the merchant templates that
//  AddWalletTransactionToYNABIntent / AddWalletTransactionToSplitwiseIntent
//  otherwise only build up interactively via Shortcuts prompts. Reads/writes
//  the same WalletTransactionConfigStore / SplitwiseWalletTransactionConfigStore
//  JSON files, so edits made here take effect on the next Wallet automation
//  run.
//

import SwiftUI
import os

private let logger = Logger(subsystem: "com.pentlandFirth.Hazel", category: "TemplatesView")

struct TemplatesView: View {
    @State private var ynabAuth = YNABAuthService()
    @State private var splitwiseAuth = SplitwiseAuthService()
    @State private var ynabConfig = WalletTransactionConfigStore.load()
    @State private var splitwiseConfig = SplitwiseWalletTransactionConfigStore.load()
    @State private var pendingDeletion: PendingDeletion?

    private enum PendingDeletion: Identifiable {
        case ynab(String)
        case splitwise(String)

        var id: String {
            switch self {
            case .ynab(let name): "ynab-\(name)"
            case .splitwise(let name): "splitwise-\(name)"
            }
        }

        var name: String {
            switch self {
            case .ynab(let name), .splitwise(let name): name
            }
        }
    }

    var body: some View {
        List {
            if ynabAuth.isAuthenticated {
                Section("YNAB") {
                    ForEach(ynabConfig.templates.keys.sorted(), id: \.self) { name in
                        NavigationLink {
                            YNABTemplateEditView(templateName: name, onSave: reloadYNAB, onDelete: reloadYNAB)
                        } label: {
                            YNABTemplateRow(name: name, template: ynabConfig.templates[name])
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) {
                                pendingDeletion = .ynab(name)
                            }
                        }
                    }
                    NavigationLink {
                        YNABTemplateEditView(templateName: nil, onSave: reloadYNAB, onDelete: reloadYNAB)
                    } label: {
                        RowLabel(title: "Add Template")
                    }
                }
                .cardRowBackground()
            }

            if splitwiseAuth.isAuthenticated {
                Section("Splitwise") {
                    ForEach(splitwiseConfig.templates.keys.sorted(), id: \.self) { name in
                        NavigationLink {
                            SplitwiseTemplateEditView(templateName: name, onSave: reloadSplitwise, onDelete: reloadSplitwise)
                        } label: {
                            SplitwiseTemplateRow(name: name, template: splitwiseConfig.templates[name])
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) {
                                pendingDeletion = .splitwise(name)
                            }
                        }
                    }
                    NavigationLink {
                        SplitwiseTemplateEditView(templateName: nil, onSave: reloadSplitwise, onDelete: reloadSplitwise)
                    } label: {
                        RowLabel(title: "Add Template")
                    }
                }
                .cardRowBackground()
            }
        }
        .themedList(background: .backgroundColor)
        .navigationTitle("Templates")
        .onAppear {
            reloadYNAB()
            reloadSplitwise()
        }
        .confirmationDialog(
            "Delete \"\(pendingDeletion?.name ?? "")\"?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                switch pendingDeletion {
                case .ynab(let name): deleteYNABTemplate(name)
                case .splitwise(let name): deleteSplitwiseTemplate(name)
                case nil: break
                }
                pendingDeletion = nil
            }
        }
    }

    private func reloadYNAB() {
        ynabConfig = WalletTransactionConfigStore.load()
    }

    private func reloadSplitwise() {
        splitwiseConfig = SplitwiseWalletTransactionConfigStore.load()
    }

    private func deleteYNABTemplate(_ name: String) {
        var config = WalletTransactionConfigStore.load()
        config.templates.removeValue(forKey: name)
        config.merchants = config.merchants.filter { $0.value.templateName != name }
        do {
            try WalletTransactionConfigStore.save(config)
            logger.log("deleted template \(name, privacy: .public)")
            reloadYNAB()
        } catch {
            logger.error("failed to delete template: \(String(describing: error), privacy: .public)")
        }
    }

    private func deleteSplitwiseTemplate(_ name: String) {
        var config = SplitwiseWalletTransactionConfigStore.load()
        config.templates.removeValue(forKey: name)
        config.merchants = config.merchants.filter { $0.value.templateName != name }
        do {
            try SplitwiseWalletTransactionConfigStore.save(config)
            logger.log("deleted template \(name, privacy: .public)")
            reloadSplitwise()
        } catch {
            logger.error("failed to delete template: \(String(describing: error), privacy: .public)")
        }
    }
}

private struct YNABTemplateRow: View {
    let name: String
    let template: WalletTransactionConfig.Template?

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(name)
                if let template {
                    Text("\(template.splitwiseOption.label) · \(template.autoMatch.count) auto-match rule\(template.autoMatch.count == 1 ? "" : "s")")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            ListChevron()
        }
    }
}

private struct SplitwiseTemplateRow: View {
    let name: String
    let template: SplitwiseWalletTransactionConfig.Template?

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(name)
                if let template {
                    Text("Split with \(template.friendFirstName) · \(template.splitOption.label)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            ListChevron()
        }
    }
}

extension SplitwiseTemplateOption {
    /// Plain-text label for use in Hazel's own SwiftUI screens — distinct
    /// from `caseDisplayRepresentations`, which is Shortcuts/Siri-only.
    var label: String {
        switch self {
        case .always: "Split Equally"
        case .manual: "Split Manually"
        case .ask: "Ask Each Time"
        case .never: "Don't Split"
        }
    }
}

#Preview {
    NavigationStack {
        TemplatesView()
    }
}
