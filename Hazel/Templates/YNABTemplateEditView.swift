//
//  YNABTemplateEditView.swift
//  Hazel
//
//  Create/edit form for a single WalletTransactionConfig.Template. Reads and
//  writes WalletTransactionConfigStore directly — the same store
//  AddWalletTransactionToYNABIntent.perform() mutates — so there's a single
//  source of truth regardless of whether a template was set up via a
//  Shortcuts run or here.
//

import SwiftUI
import os

private let logger = Logger(subsystem: "com.pentlandFirth.Hazel", category: "YNABTemplateEditView")

private struct LinkedMerchant: Identifiable {
    let merchant: String
    let payeeName: String
    var id: String { merchant }
}

struct YNABTemplateEditView: View {
    /// nil means "creating a new template".
    let templateName: String?
    var onSave: () -> Void
    var onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var splitwiseAuth = SplitwiseAuthService()
    @State private var name: String
    @State private var categories: [YNABCategory] = []
    @State private var selectedCategoryId: String?
    @State private var splitwiseOption: SplitwiseTemplateOption
    @State private var autoMatchRules: [WalletTransactionConfig.AutoMatchRule]
    @State private var linkedMerchants: [LinkedMerchant]
    @State private var otherTemplateNames: [String]
    @State private var isLoadingCategories = false
    @State private var errorMessage: String?
    @State private var showDeleteConfirmation = false

    init(templateName: String?, onSave: @escaping () -> Void, onDelete: @escaping () -> Void) {
        self.templateName = templateName
        self.onSave = onSave
        self.onDelete = onDelete
        let config = WalletTransactionConfigStore.load()
        let existing = templateName.flatMap { config.templates[$0] }
        _name = State(initialValue: templateName ?? "")
        _selectedCategoryId = State(initialValue: existing?.categoryId)
        _splitwiseOption = State(initialValue: existing?.splitwiseOption ?? .never)
        _autoMatchRules = State(initialValue: existing?.autoMatch ?? [])
        _linkedMerchants = State(initialValue: config.merchants
            .filter { $0.value.templateName == templateName }
            .map { LinkedMerchant(merchant: $0.key, payeeName: $0.value.payeeName) }
            .sorted { $0.merchant < $1.merchant })
        _otherTemplateNames = State(initialValue: config.templates.keys
            .filter { $0 != templateName }
            .sorted())
    }

    var body: some View {
        Form {
            Section("Name") {
                TextField("Template Name", text: $name)
            }

            Section("Category") {
                if isLoadingCategories {
                    ProgressView()
                } else {
                    Picker("Category", selection: $selectedCategoryId) {
                        Text("None").tag(String?.none)
                        ForEach(categories, id: \.id) { category in
                            Text(category.name).tag(Optional(category.id))
                        }
                    }
                }
            }

            if splitwiseAuth.isAuthenticated {
                Section("Splitwise") {
                    Picker("Split Option", selection: $splitwiseOption) {
                        ForEach([SplitwiseTemplateOption.ask, .always, .manual, .never], id: \.self) { option in
                            Text(option.label).tag(option)
                        }
                    }
                }
            }

            Section("Auto-Match Rules") {
                ForEach(autoMatchRules.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Pattern (text or regex)", text: $autoMatchRules[index].pattern)
                        TextField("Payee Name", text: $autoMatchRules[index].payeeName)
                    }
                }
                .onDelete { autoMatchRules.remove(atOffsets: $0) }
                Button("Add Rule") {
                    autoMatchRules.append(.init(pattern: "", payeeName: ""))
                }
            }

            if templateName != nil, !linkedMerchants.isEmpty {
                Section {
                    ForEach(linkedMerchants) { linked in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(linked.merchant)
                                Text(linked.payeeName)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !otherTemplateNames.isEmpty {
                                Menu {
                                    ForEach(otherTemplateNames, id: \.self) { destination in
                                        Button(destination) { move(linked, to: destination) }
                                    }
                                } label: {
                                    Image(systemName: "arrow.turn.up.right")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .onDelete { linkedMerchants.remove(atOffsets: $0) }
                } header: {
                    Text("Linked Merchants")
                } footer: {
                    Text("Wallet transactions from these exact merchant names go straight to this template. Swipe to unlink one, or use the arrow to move one to a different template.")
                }
            }

            if templateName != nil {
                Section {
                    Button("Delete Template", role: .destructive) {
                        showDeleteConfirmation = true
                    }
                }
            }

            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
        }
        .navigationTitle(templateName ?? "New Template")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .task { await loadCategories() }
        .confirmationDialog(
            "Delete this template?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive, action: delete)
        }
    }

    private func loadCategories() async {
        guard let token = await YNABAuthService.validAccessToken() else {
            logger.error("no YNAB access token — not authenticated")
            return
        }
        if let cached = YNABCategoryCacheStore.load() {
            categories = YNABCategoryUsageStore.sorted(cached)
        }
        isLoadingCategories = categories.isEmpty
        defer { isLoadingCategories = false }
        do {
            let fetched = try await YNABCategoryCacheStore.fetch(token: token)
            categories = YNABCategoryUsageStore.sorted(fetched)
        } catch {
            logger.error("failed to load categories: \(String(describing: error), privacy: .public)")
            if categories.isEmpty {
                errorMessage = "Failed to load categories: \(error.localizedDescription)"
            }
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        var config = WalletTransactionConfigStore.load()
        if trimmedName != templateName, config.templates[trimmedName] != nil {
            errorMessage = "A template named \"\(trimmedName)\" already exists."
            return
        }

        let cleanedRules = autoMatchRules.filter { !$0.pattern.isEmpty && !$0.payeeName.isEmpty }
        let template = WalletTransactionConfig.Template(
            categoryId: selectedCategoryId,
            autoMatch: cleanedRules,
            splitwiseOption: splitwiseOption
        )

        if let templateName {
            // Drop merchants unlinked in this session before any rename
            // propagation below, so they aren't renamed back in.
            let keptMerchants = Set(linkedMerchants.map(\.merchant))
            for key in config.merchants.keys where config.merchants[key]?.templateName == templateName {
                if !keptMerchants.contains(key) {
                    config.merchants.removeValue(forKey: key)
                }
            }
            if templateName != trimmedName {
                config.templates.removeValue(forKey: templateName)
                for key in config.merchants.keys where config.merchants[key]?.templateName == templateName {
                    config.merchants[key]?.templateName = trimmedName
                }
            }
        }
        config.templates[trimmedName] = template

        do {
            try WalletTransactionConfigStore.save(config)
            logger.log("saved template \(trimmedName, privacy: .public)")
            onSave()
            dismiss()
        } catch {
            logger.error("failed to save template: \(String(describing: error), privacy: .public)")
            errorMessage = "Failed to save: \(error.localizedDescription)"
        }
    }

    private func delete() {
        guard let templateName else { return }
        var config = WalletTransactionConfigStore.load()
        config.templates.removeValue(forKey: templateName)
        config.merchants = config.merchants.filter { $0.value.templateName != templateName }
        do {
            try WalletTransactionConfigStore.save(config)
            logger.log("deleted template \(templateName, privacy: .public)")
            onDelete()
            dismiss()
        } catch {
            logger.error("failed to delete template: \(String(describing: error), privacy: .public)")
            errorMessage = "Failed to delete: \(error.localizedDescription)"
        }
    }

    /// Repoints a merchant at a different, existing template, independent of
    /// this screen's own pending edits/Save — the merchant no longer belongs
    /// to the template being edited here, so there's nothing for this
    /// screen's save() to reconcile once it's removed from `linkedMerchants`.
    private func move(_ linked: LinkedMerchant, to destinationTemplate: String) {
        var config = WalletTransactionConfigStore.load()
        config.merchants[linked.merchant]?.templateName = destinationTemplate
        do {
            try WalletTransactionConfigStore.save(config)
            linkedMerchants.removeAll { $0.id == linked.id }
            logger.log("moved merchant \(linked.merchant, privacy: .public) to template \(destinationTemplate, privacy: .public)")
        } catch {
            logger.error("failed to move merchant: \(String(describing: error), privacy: .public)")
            errorMessage = "Failed to move \(linked.merchant): \(error.localizedDescription)"
        }
    }
}

#Preview {
    NavigationStack {
        YNABTemplateEditView(templateName: nil, onSave: {}, onDelete: {})
    }
}
