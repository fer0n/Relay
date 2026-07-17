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

/// Everything Save actually persists, in one place, so "has anything
/// changed?" is a single Equatable comparison instead of a field-by-field
/// list that has to be kept in sync by hand as fields are added.
private struct TemplateDraft: Equatable {
    var name: String
    var categoryId: String?
    var splitwiseOption: SplitwiseTemplateOption
    var friendId: Int?
    var autoMatchRules: [WalletTransactionConfig.AutoMatchRule]
    var linkedMerchants: [LinkedMerchant]
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

    /// The app-wide default (Settings' DefaultSplitwiseFriendRow) — leaving
    /// this template's own friend unset doesn't mean "split with no one",
    /// it means "use this" (see AddWalletTransactionToYNABIntent's
    /// splitwiseFriendFallback), so the picker/footer below should say so
    /// instead of showing a bare "None".
    private let defaultFriend: SplitwiseDefaultFriend?

    /// Snapshot of the loaded state, compared against `currentDraft` in
    /// `hasChanges` so the Save bar only appears once something's actually
    /// been edited.
    private let originalDraft: TemplateDraft

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
        defaultFriend = SplitwiseDefaultFriendStore.load()
        _autoMatchRules = State(initialValue: existing?.autoMatch ?? [])
        let linkedMerchants = config.merchants
            .filter { $0.value.templateName == templateName }
            .map { LinkedMerchant(merchant: $0.key, payeeName: $0.value.payeeName) }
            .sorted { $0.merchant < $1.merchant }
        _linkedMerchants = State(initialValue: linkedMerchants)
        _otherTemplateNames = State(initialValue: config.templates.keys
            .filter { $0 != templateName }
            .sorted())

        originalDraft = TemplateDraft(
            name: templateName ?? "",
            categoryId: existing?.categoryId,
            splitwiseOption: existing?.splitwiseOption ?? .never,
            friendId: existing?.splitwiseFriendId,
            autoMatchRules: existing?.autoMatch ?? [],
            linkedMerchants: linkedMerchants
        )
    }

    /// Mirrors what `save()` would actually write, cleaned/trimmed the same
    /// way, so it can be compared directly against `originalDraft`.
    private var currentDraft: TemplateDraft {
        TemplateDraft(
            name: name.trimmingCharacters(in: .whitespaces),
            categoryId: selectedCategoryId,
            splitwiseOption: splitwiseOption,
            friendId: selectedFriendId,
            autoMatchRules: autoMatchRules.filter { !$0.pattern.isEmpty && !$0.payeeName.isEmpty },
            linkedMerchants: linkedMerchants.map {
                LinkedMerchant(merchant: $0.merchant, payeeName: $0.payeeName.trimmingCharacters(in: .whitespaces))
            }
        )
    }

    /// Whether anything differs from what was loaded, i.e. whether Save has
    /// anything to persist.
    private var hasChanges: Bool {
        currentDraft != originalDraft
    }

    var body: some View {
        List {
            Section {
                DraftDetailRow(icon: "textformat", title: "Name") {
                    TextField("Template Name", text: $name)
                        .multilineTextAlignment(.trailing)
                }

                if ynabAuth.isAuthenticated {
                    DraftDetailRow(icon: "tag.fill", title: "Category") {
                        if isLoadingCategories {
                            ProgressView()
                        } else {
                            MenuPickerField(
                                selection: $selectedCategoryId,
                                label: categories.first { $0.id == selectedCategoryId }?.name ?? "None"
                            ) {
                                Text("None").tag(String?.none)
                                ForEach(categories, id: \.id) { category in
                                    Text(category.name).tag(Optional(category.id))
                                }
                            }
                        }
                    }
                }
            }
            .cardRowBackground()

            if splitwiseAuth.isAuthenticated {
                Section {
                    SplitwiseOptionRow(
                        title: "Split Option",
                        isResolved: false,
                        resolvedOption: .never,
                        newOption: $splitwiseOption
                    )
                    SplitwiseFriendPickerRow(
                        isLoading: isLoadingFriends,
                        friends: friends,
                        selectedFriendId: $selectedFriendId,
                        noneLabel: defaultFriend.map { "Default (\($0.firstName))" } ?? "None"
                    )
                } header: {
                    Text("Splitwise")
                } footer: {
                    if defaultFriend != nil {
                        Text("\"Split With\" is optional — if it's left as Default, the app-wide default Splitwise friend (set in Settings) is used when a matching transaction needs to split.")
                            .footerText()
                    } else {
                        Text("\"Split With\" is optional — if it's left as None, you'll be asked to pick a friend the first time a matching transaction needs to split.")
                            .footerText()
                    }
                }
            }

            AutoMatchRulesSection(rules: $autoMatchRules)

            if templateName != nil, !linkedMerchants.isEmpty {
                LinkedMerchantsSection(
                    linkedMerchants: $linkedMerchants,
                    otherTemplateNames: otherTemplateNames,
                    onMove: move
                )
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
                .listRowBackground(Color.backgroundColor)
            }
        }
        .themedList(background: .backgroundColor)
        .navigationTitle(templateName ?? "New Template")
        .toolbar {
            if templateName != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Image(systemName: "trash.fill")
                    }
                }
            }
        }
        .safeAreaBar(edge: .bottom) {
            if hasChanges {
                Button(action: save) {
                    Text("Save")
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .themedText()
                }
                .glassProminentActionButton()
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
        defaultFriend = nil
        _name = State(initialValue: "Groceries")
        _selectedCategoryId = State(initialValue: nil)
        _splitwiseOption = State(initialValue: .never)
        _selectedFriendId = State(initialValue: nil)
        _autoMatchRules = State(initialValue: previewAutoMatchRules)
        _linkedMerchants = State(initialValue: [])
        _otherTemplateNames = State(initialValue: [])
        originalDraft = TemplateDraft(
            name: "Groceries",
            categoryId: nil,
            splitwiseOption: .never,
            friendId: nil,
            autoMatchRules: previewAutoMatchRules,
            linkedMerchants: []
        )
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
