//
//  SplitwiseTemplateEditView.swift
//  Hazel
//
//  Create/edit form for a single SplitwiseWalletTransactionConfig.Template.
//  Mirrors YNABTemplateEditView.swift's shape, reading/writing
//  SplitwiseWalletTransactionConfigStore directly — the same store
//  AddWalletTransactionToSplitwiseIntent.perform() mutates.
//

import SwiftUI
import os

private let logger = Logger(subsystem: "com.pentlandFirth.Hazel", category: "SplitwiseTemplateEditView")

private struct LinkedMerchant: Identifiable {
    let merchant: String
    let expenseDescription: String
    var id: String { merchant }
}

struct SplitwiseTemplateEditView: View {
    /// nil means "creating a new template".
    let templateName: String?
    var onSave: () -> Void
    var onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var friends: [SplitwiseFriend] = []
    @State private var selectedFriendId: Int?
    @State private var splitOption: SplitwiseTemplateOption
    @State private var autoMatchRules: [SplitwiseWalletTransactionConfig.AutoMatchRule]
    @State private var linkedMerchants: [LinkedMerchant]
    @State private var otherTemplateNames: [String]
    @State private var isLoadingFriends = false
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
        let config = SplitwiseWalletTransactionConfigStore.load()
        let existing = templateName.flatMap { config.templates[$0] }
        existingFriend = existing.map { ($0.friendId, $0.friendFirstName, $0.friendFullName) }
        _name = State(initialValue: templateName ?? "")
        _selectedFriendId = State(initialValue: existing?.friendId)
        _splitOption = State(initialValue: existing?.splitOption ?? .never)
        _autoMatchRules = State(initialValue: existing?.autoMatch ?? [])
        _linkedMerchants = State(initialValue: config.merchants
            .filter { $0.value.templateName == templateName }
            .map { LinkedMerchant(merchant: $0.key, expenseDescription: $0.value.expenseDescription) }
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

            Section("Split With") {
                if isLoadingFriends {
                    ProgressView()
                } else {
                    Picker("Friend", selection: $selectedFriendId) {
                        Text("None").tag(Int?.none)
                        ForEach(friends, id: \.id) { friend in
                            Text(friend.fullName).tag(Optional(friend.id))
                        }
                    }
                }
            }

            Section("Splitwise") {
                Picker("Split Option", selection: $splitOption) {
                    ForEach([SplitwiseTemplateOption.always, .manual, .ask, .never], id: \.self) { option in
                        Text(option.label).tag(option)
                    }
                }
            }

            Section("Auto-Match Rules") {
                ForEach(autoMatchRules.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Pattern (text or regex)", text: $autoMatchRules[index].pattern)
                        TextField("Description", text: $autoMatchRules[index].expenseDescription)
                    }
                }
                .onDelete { autoMatchRules.remove(atOffsets: $0) }
                Button("Add Rule") {
                    autoMatchRules.append(.init(pattern: "", expenseDescription: ""))
                }
            }

            if templateName != nil, !linkedMerchants.isEmpty {
                Section {
                    ForEach(linkedMerchants) { linked in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(linked.merchant)
                                Text(linked.expenseDescription)
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
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || selectedFriendId == nil)
            }
        }
        .task { await loadFriends() }
        .confirmationDialog(
            "Delete this template?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive, action: delete)
        }
    }

    private func loadFriends() async {
        guard let token = SplitwiseAuthService.currentAccessToken else {
            logger.error("no Splitwise access token — not authenticated")
            return
        }
        isLoadingFriends = true
        defer { isLoadingFriends = false }
        do {
            let fetched = try await SplitwiseService.fetchFriends(token: token)
            friends = SplitwiseFriendUsageStore.sorted(fetched)
        } catch {
            logger.error("failed to load friends: \(String(describing: error), privacy: .public)")
            errorMessage = "Failed to load friends: \(error.localizedDescription)"
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty, let selectedFriendId else { return }

        let resolvedFriend: (id: Int, firstName: String, fullName: String)
        if let match = friends.first(where: { $0.id == selectedFriendId }) {
            resolvedFriend = (match.id, match.firstName, match.fullName)
        } else if let existingFriend, existingFriend.id == selectedFriendId {
            resolvedFriend = existingFriend
        } else {
            errorMessage = "Selected friend not found."
            return
        }

        var config = SplitwiseWalletTransactionConfigStore.load()
        if trimmedName != templateName, config.templates[trimmedName] != nil {
            errorMessage = "A template named \"\(trimmedName)\" already exists."
            return
        }

        let cleanedRules = autoMatchRules.filter { !$0.pattern.isEmpty && !$0.expenseDescription.isEmpty }
        let template = SplitwiseWalletTransactionConfig.Template(
            friendId: resolvedFriend.id,
            friendFirstName: resolvedFriend.firstName,
            friendFullName: resolvedFriend.fullName,
            splitOption: splitOption,
            autoMatch: cleanedRules
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
            try SplitwiseWalletTransactionConfigStore.save(config)
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
        var config = SplitwiseWalletTransactionConfigStore.load()
        config.templates.removeValue(forKey: templateName)
        config.merchants = config.merchants.filter { $0.value.templateName != templateName }
        do {
            try SplitwiseWalletTransactionConfigStore.save(config)
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
        var config = SplitwiseWalletTransactionConfigStore.load()
        config.merchants[linked.merchant]?.templateName = destinationTemplate
        do {
            try SplitwiseWalletTransactionConfigStore.save(config)
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
        SplitwiseTemplateEditView(templateName: nil, onSave: {}, onDelete: {})
    }
}
