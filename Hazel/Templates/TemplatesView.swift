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

struct TemplatesView: View {
    @State private var ynabConfig = WalletTransactionConfigStore.load()
    @State private var splitwiseConfig = SplitwiseWalletTransactionConfigStore.load()

    var body: some View {
        List {
            Section("YNAB") {
                ForEach(ynabConfig.templates.keys.sorted(), id: \.self) { name in
                    NavigationLink {
                        YNABTemplateEditView(templateName: name, onSave: reloadYNAB, onDelete: reloadYNAB)
                    } label: {
                        YNABTemplateRow(name: name, template: ynabConfig.templates[name])
                    }
                }
                NavigationLink {
                    YNABTemplateEditView(templateName: nil, onSave: reloadYNAB, onDelete: reloadYNAB)
                } label: {
                    RowLabel(title: "Add Template")
                }
            }
            .cardRowBackground()

            Section("Splitwise") {
                ForEach(splitwiseConfig.templates.keys.sorted(), id: \.self) { name in
                    NavigationLink {
                        SplitwiseTemplateEditView(templateName: name, onSave: reloadSplitwise, onDelete: reloadSplitwise)
                    } label: {
                        SplitwiseTemplateRow(name: name, template: splitwiseConfig.templates[name])
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
        .themedList(background: .backgroundColor)
        .navigationTitle("Templates")
        .onAppear {
            reloadYNAB()
            reloadSplitwise()
        }
    }

    private func reloadYNAB() {
        ynabConfig = WalletTransactionConfigStore.load()
    }

    private func reloadSplitwise() {
        splitwiseConfig = SplitwiseWalletTransactionConfigStore.load()
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
