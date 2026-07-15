//
//  TemplateEditView.swift
//  Hazel
//
//  Create/edit form for a single WalletTransactionConfig.Template, shared by
//  both YNAB and Splitwise wallet automations — a template used to be split
//  into two separate per-provider types/screens; now one template can carry
//  a YNAB category, a Splitwise split option/friend, or both, with each
//  provider's fields hidden here when that provider isn't connected.
//  AddWalletTransactionToYNABIntent and AddWalletTransactionToSplitwiseIntent
//  both read/write this same WalletTransactionConfigStore.
//

import SwiftUI
import os

private let logger = Logger(subsystem: "com.pentlandFirth.Hazel", category: "TemplateEditView")

private struct LinkedMerchant: Identifiable {
    let merchant: String
    var payeeName: String
    var id: String { merchant }
}

struct TemplateEditView: View {
    /// nil means "creating a new template".
    let templateName: String?
    var onSave: () -> Void
    var onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var ynabAuth = YNABAuthService()
    @State private var splitwiseAuth = SplitwiseAuthService()

    @State private var name: String

    @State private var categories: [YNABCategory] = []
    @State private var selectedCategoryId: String?
    @State private var isLoadingCategories = false

    @State private var friends: [SplitwiseFriend] = []
    @State private var selectedFriendId: Int?
    @State private var splitwiseOption: SplitwiseTemplateOption
    @State private var isLoadingFriends = false

    @State private var autoMatchRules: [WalletTransactionConfig.AutoMatchRule]
    @State private var linkedMerchants: [LinkedMerchant]
    @State private var otherTemplateNames: [String]
    @State private var errorMessage: String?
    @State private var showDeleteConfirmation = false

    /// Fallback used at save time if the existing template's friend no
    /// longer appears in a fresh fetchFriends() (e.g. fetch still in
    /// flight, or the friend was removed on Splitwise) but the selection
    /// hasn't changed from what was already saved.
    private let existingFriend: (id: Int, firstName: String, fullName: String)?

    init(templateName: String?, onSave: @escaping () -> Void, onDelete: @escaping () -> Void) {
        self.templateName = templateName
        self.onSave = onSave
        self.onDelete = onDelete
        let config = WalletTransactionConfigStore.load()
        let existing = templateName.flatMap { config.templates[$0] }
        _name = State(initialValue: templateName ?? "")
        _selectedCategoryId = State(initialValue: existing?.categoryId)
        _splitwiseOption = State(initialValue: existing?.splitwiseOption ?? .never)
        _selectedFriendId = State(initialValue: existing?.splitwiseFriendId)
        existingFriend = existing?.splitwiseFriend
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

            if ynabAuth.isAuthenticated {
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
            }

            if splitwiseAuth.isAuthenticated {
                Section {
                    Picker("Split Option", selection: $splitwiseOption) {
                        ForEach([SplitwiseTemplateOption.ask, .always, .manual, .never], id: \.self) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    if isLoadingFriends {
                        ProgressView()
                    } else {
                        Picker("Split With", selection: $selectedFriendId) {
                            Text("None").tag(Int?.none)
                            ForEach(friends, id: \.id) { friend in
                                Text(friend.fullName).tag(Optional(friend.id))
                            }
                        }
                    }
                } header: {
                    Text("Splitwise")
                } footer: {
                    Text("\"Split With\" is optional — if it's left as None, you'll be asked to pick a friend the first time a matching transaction needs to split.")
                }
            }

            Section {
                if !autoMatchRules.isEmpty {
                    HStack {
                        Text("Payee Name")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Pattern")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                ForEach(autoMatchRules.indices, id: \.self) { index in
                    HStack {
                        TextField("Payee Name", text: $autoMatchRules[index].payeeName)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Divider()
                        TextField("Text or regex", text: $autoMatchRules[index].pattern)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .onDelete { autoMatchRules.remove(atOffsets: $0) }
                Button("Add Rule") {
                    autoMatchRules.append(.init(pattern: "", payeeName: ""))
                }
            } header: {
                Text("Auto-Match Rules")
            } footer: {
                Text("Pattern can be plain text or a regex, and is matched case-insensitively.")
            }

            if templateName != nil, !linkedMerchants.isEmpty {
                Section {
                    ForEach(linkedMerchants.indices, id: \.self) { index in
                        let linked = linkedMerchants[index]
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(linked.merchant)
                                TextField("Payee Name", text: $linkedMerchants[index].payeeName)
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
                    Text("Wallet transactions from these exact merchant names go straight to this template. Edit the payee name, swipe to unlink one, or use the arrow to move one to a different template.")
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
        .task {
            await loadCategories()
            await loadFriends()
        }
        .confirmationDialog(
            "Delete this template?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive, action: delete)
        }
    }

    private func loadCategories() async {
        guard ynabAuth.isAuthenticated, let token = await YNABAuthService.validAccessToken() else { return }
        if let cached = YNABCategoryCacheStore.load() {
            categories = YNABCategoryUsageStore.sorted(cached)
        }
        isLoadingCategories = categories.isEmpty
        defer { isLoadingCategories = false }
        do {
            categories = YNABCategoryUsageStore.sorted(try await YNABCategoryCacheStore.fetch(token: token))
        } catch {
            logger.error("failed to load categories: \(String(describing: error), privacy: .public)")
            if categories.isEmpty {
                errorMessage = "Failed to load categories: \(error.localizedDescription)"
            }
        }
    }

    private func loadFriends() async {
        guard splitwiseAuth.isAuthenticated, let token = SplitwiseAuthService.currentAccessToken else { return }
        if let cached = SplitwiseFriendCacheStore.load() {
            friends = SplitwiseFriendUsageStore.sorted(cached)
        }
        isLoadingFriends = friends.isEmpty
        defer { isLoadingFriends = false }
        do {
            friends = SplitwiseFriendUsageStore.sorted(try await SplitwiseFriendCacheStore.fetch(token: token))
        } catch {
            logger.error("failed to load friends: \(String(describing: error), privacy: .public)")
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

        let resolvedFriend: (id: Int, firstName: String, fullName: String)?
        if let selectedFriendId {
            if let match = friends.first(where: { $0.id == selectedFriendId }) {
                resolvedFriend = (match.id, match.firstName, match.fullName)
            } else if let existingFriend, existingFriend.id == selectedFriendId {
                resolvedFriend = existingFriend
            } else {
                resolvedFriend = nil
            }
        } else {
            resolvedFriend = nil
        }

        let template = WalletTransactionConfig.Template(
            categoryId: selectedCategoryId,
            autoMatch: cleanedRules,
            splitwiseOption: splitwiseOption,
            splitwiseFriendId: resolvedFriend?.id,
            splitwiseFriendFirstName: resolvedFriend?.firstName,
            splitwiseFriendFullName: resolvedFriend?.fullName
        )

        if let templateName {
            // Drop merchants unlinked in this session before the loop below
            // rewrites the rest, so they aren't added back in.
            let keptMerchants = Set(linkedMerchants.map(\.merchant))
            for key in config.merchants.keys where config.merchants[key]?.templateName == templateName {
                if !keptMerchants.contains(key) {
                    config.merchants.removeValue(forKey: key)
                }
            }
            if templateName != trimmedName {
                config.templates.removeValue(forKey: templateName)
            }
        }
        config.templates[trimmedName] = template

        // Rewrites every kept linked merchant with its (possibly edited)
        // payee name and the template's current name, covering both plain
        // edits and a template rename in one pass.
        for linked in linkedMerchants {
            config.merchants[linked.merchant] = WalletTransactionConfig.MerchantInfo(
                payeeName: linked.payeeName.trimmingCharacters(in: .whitespaces),
                templateName: trimmedName
            )
        }

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
        config.merchants[linked.merchant] = WalletTransactionConfig.MerchantInfo(
            payeeName: linked.payeeName.trimmingCharacters(in: .whitespaces),
            templateName: destinationTemplate
        )
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

#if DEBUG
extension TemplateEditView {
    /// Preview-only initializer that seeds sample auto-match rules directly,
    /// bypassing WalletTransactionConfigStore so previewing never touches
    /// the real on-disk config.
    init(previewAutoMatchRules: [WalletTransactionConfig.AutoMatchRule]) {
        self.templateName = nil
        self.onSave = {}
        self.onDelete = {}
        existingFriend = nil
        _name = State(initialValue: "Groceries")
        _selectedCategoryId = State(initialValue: nil)
        _splitwiseOption = State(initialValue: .never)
        _selectedFriendId = State(initialValue: nil)
        _autoMatchRules = State(initialValue: previewAutoMatchRules)
        _linkedMerchants = State(initialValue: [])
        _otherTemplateNames = State(initialValue: [])
    }
}
#endif

#Preview {
    NavigationStack {
        TemplateEditView(previewAutoMatchRules: [
            .init(pattern: "STARBUCKS", payeeName: "Starbucks"),
            .init(pattern: "(?i)uber( eats)?", payeeName: "Uber Eats"),
            .init(pattern: "TRADER JOE'?S", payeeName: "Trader Joe's")
        ])
    }
}
