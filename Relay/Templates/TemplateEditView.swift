//
//  TemplateEditView.swift
//  Relay
//
//  Create/edit form for one WalletTransactionConfig.Template, which can carry a
//  YNAB category, a split option/target, or both — each provider's
//  fields hidden when that provider isn't connected.
//

import SwiftUI
import os

private let logger = Logger(subsystem: Const.loggerSubsystem, category: "TemplateEditView")

/// Everything Save persists, in one place, so "has anything changed?" is one
/// Equatable comparison rather than a hand-maintained field-by-field list.
private struct TemplateDraft: Equatable {
    var name: String
    var categoryId: String?
    var splitOption: SplitTemplateOption
    var target: WalletTransactionConfig.CachedSplitTarget?
    var autoMatchRules: [WalletTransactionConfig.AutoMatchRule]
    var linkedMerchants: [LinkedMerchant]
}

struct TemplateEditView: View {
    /// nil means "creating a new template".
    let templateName: String?
    var onSave: (String) -> Void
    var onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var ynabAuth = YNABAuthService()

    @State private var name: String

    @State private var categories: [YNABCategory] = []
    @State private var selectedCategoryId: String?
    @State private var isLoadingCategories = false

    @State private var ledgerStore = LedgerStore.shared

    private var availableLedgers: [Ledger] { ledgerStore.sharedLedgers }
    @State private var selectedTarget: WalletTransactionConfig.CachedSplitTarget?
    @State private var splitOption: SplitTemplateOption
    @State private var isLoadingFriends = false

    @State private var autoMatchRules: [WalletTransactionConfig.AutoMatchRule]
    @State private var linkedMerchants: [LinkedMerchant]
    @State private var otherTemplateNames: [String]
    @State private var errorMessage: String?
    @State private var showDeleteConfirmation = false


    /// Leaving this template's friend unset means "use the app-wide default", not
    /// "split with no one", so the picker names it rather than showing "None".
    private let defaultTarget: WalletTransactionConfig.CachedSplitTarget?

    /// Compared against `currentDraft` so the Save bar only appears once something
    /// has actually been edited.
    private let originalDraft: TemplateDraft

    init(templateName: String?, onSave: @escaping (String) -> Void, onDelete: @escaping () -> Void) {
        self.templateName = templateName
        self.onSave = onSave
        self.onDelete = onDelete
        let config = WalletTransactionConfigStore.load()
        let existing = templateName.flatMap { config.templates[$0] }
        _name = State(initialValue: templateName ?? "")
        _selectedCategoryId = State(initialValue: existing?.categoryId)
        _splitOption = State(initialValue: existing?.splitOption ?? .never)
        _selectedTarget = State(initialValue: existing?.splitTarget)
        defaultTarget = DefaultSplitTargetStore.load()
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
            splitOption: existing?.splitOption ?? .never,
            target: existing?.splitTarget,
            autoMatchRules: existing?.autoMatch ?? [],
            linkedMerchants: linkedMerchants
        )
    }

    /// Trimmed exactly as `save()` would write it, so it compares directly against
    /// `originalDraft`.
    private var currentDraft: TemplateDraft {
        TemplateDraft(
            name: name.trimmingCharacters(in: .whitespaces),
            categoryId: selectedCategoryId,
            splitOption: splitOption,
            target: selectedTarget,
            autoMatchRules: autoMatchRules.filter { !$0.pattern.isEmpty && !$0.payeeName.isEmpty },
            linkedMerchants: linkedMerchants.map {
                LinkedMerchant(merchant: $0.merchant, payeeName: $0.payeeName.trimmingCharacters(in: .whitespaces))
            }
        )
    }

private var hasChanges: Bool {
        currentDraft != originalDraft
    }

    var body: some View {
        List {
            Section {
                DraftDetailRow(icon: "textformat", title: "Name") {
                    TextField("Template Name", text: $name)
                        .multilineTextAlignment(.trailing)
                        .submitLabel(.done)
                }

                if ynabAuth.isAuthenticated {
                    DraftDetailRow(icon: Const.Symbol.category, title: "Category") {
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

            // Either backend is reason to show this section — a template is
            // still worth a split setting when a ledger
            // is all that's left.
            if !availableLedgers.isEmpty {
                Section {
                    SplitOptionRow(
                        title: "Split Option",
                        isResolved: false,
                        resolvedOption: .never,
                        newOption: $splitOption
                    )
                    SplitTargetPickerRow(
                        isLoading: isLoadingFriends,
                        ledgers: availableLedgers,
                        target: $selectedTarget,
                        noneLabel: defaultTarget.map { "Default (\($0.firstName))" } ?? "None"
                    )
                } header: {
                    Text("Split")
                } footer: {
                    if defaultTarget != nil {
                        Text("\"Split With\" is optional — if it's left as Default, the app-wide default (set in Settings) is used when a matching transaction needs to split.")
                            .footerText()
                    } else {
                        Text("\"Split With\" is optional — if it's left as None, you'll be asked to pick someone the first time a matching transaction needs to split.")
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
                        Image(systemName: Const.Symbol.delete)
                    }
                }
            }
        }
        .bottomBarActionButton(
            isPresented: hasChanges,
            title: "Save",
            isDisabled: name.trimmingCharacters(in: .whitespaces).isEmpty,
            action: save
        )
        .task {
            await loadCategories()
            await loadFriends()
            await ledgerStore.refresh(force: false)
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
        // Skip the live fetch while the cache is fresh — YNAB allows 200 req/hr.
        guard YNABCategoryCacheStore.isStale else { return }
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
        isLoadingFriends = availableLedgers.isEmpty
        defer { isLoadingFriends = false }
        await ledgerStore.refresh(force: false)
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

        // The picker hands over the names as well as the ids, so nothing here
        // has to survive the ledger's participant list changing under it.
        let resolvedTarget = selectedTarget

        // save() rebuilds the template from the form's fields, which don't include
        // the "default split template" flag, so carry it across by hand.
        let wasSplitDefault = templateName.flatMap { config.templates[$0]?.isSplitDefault } ?? false

        let template = WalletTransactionConfig.Template(
            categoryId: selectedCategoryId,
            isSplitDefault: wasSplitDefault,
            autoMatch: cleanedRules,
            splitOption: splitOption,
            ledgerZoneName: resolvedTarget?.zoneName,
            ledgerParticipantID: resolvedTarget?.participantID,
            splitTargetFirstName: resolvedTarget?.firstName,
            splitTargetFullName: resolvedTarget?.fullName
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

        // Rewrites every kept merchant with its payee name and the template's
        // current name, covering plain edits and a rename in one pass.
        var renamedMerchants: [(merchant: String, payeeName: String)] = []
        for linked in linkedMerchants {
            let trimmedPayeeName = linked.payeeName.trimmingCharacters(in: .whitespaces)
            if config.merchants[linked.merchant]?.payeeName != trimmedPayeeName {
                renamedMerchants.append((linked.merchant, trimmedPayeeName))
            }
            config.merchants[linked.merchant] = WalletTransactionConfig.MerchantInfo(
                payeeName: trimmedPayeeName,
                templateName: trimmedName
            )
        }

        do {
            try WalletTransactionConfigStore.save(config)
            // Carries a payee rename onto any frozen "Recent" entry recorded
            // from that merchant, so it doesn't keep showing the old name.
            for renamed in renamedMerchants {
                TransactionHistoryStore.updateTitles(forMerchant: renamed.merchant, title: renamed.payeeName)
            }
            logger.log("saved template \(trimmedName, privacy: .public)")
            onSave(trimmedName)
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
            // Deferred a tick so the confirmation dialog finishes dismissing on
            // its own before the pop/row-removal animation starts, matching
            // TemplatesView's swipe-to-delete handling.
            Task { @MainActor in
                withAnimation { onDelete() }
                dismiss()
            }
        } catch {
            logger.error("failed to delete template: \(String(describing: error), privacy: .public)")
            errorMessage = "Failed to delete: \(error.localizedDescription)"
        }
    }

    /// Repoints a merchant at another template, independent of this screen's Save:
    /// once it leaves `linkedMerchants` there's nothing for save() to reconcile.
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
    /// Bypasses WalletTransactionConfigStore so previewing never touches the real
    /// on-disk config.
    init(previewAutoMatchRules: [WalletTransactionConfig.AutoMatchRule]) {
        self.templateName = nil
        self.onSave = { _ in }
        self.onDelete = {}
        defaultTarget = nil
        _name = State(initialValue: "Groceries")
        _selectedCategoryId = State(initialValue: nil)
        _splitOption = State(initialValue: .never)
        _selectedTarget = State(initialValue: nil)
        _autoMatchRules = State(initialValue: previewAutoMatchRules)
        _linkedMerchants = State(initialValue: [])
        _otherTemplateNames = State(initialValue: [])
        originalDraft = TemplateDraft(
            name: "Groceries",
            categoryId: nil,
            splitOption: .never,
            target: nil,
            autoMatchRules: previewAutoMatchRules,
            linkedMerchants: []
        )
    }
}
#endif

#Preview {
    @Previewable @State var isPresented = true

    // Seed a template with auto-match rules and linked merchants so the
    // form shows real-looking content instead of empty placeholders.
    var config = WalletTransactionConfigStore.load()
    config.templates["Coffee Shop"] = {
        var t = WalletTransactionConfig.Template()
        t.autoMatch = [
            .init(pattern: "STARBUCKS.*", payeeName: "Starbucks"),
            .init(pattern: "coffee bean", payeeName: "Coffee Bean"),
        ]
        return t
    }()
    config.merchants["STARBUCKS #1234"] = .init(payeeName: "Starbucks", templateName: "Coffee Shop")
    config.merchants["STARBUCKS DRIVE-THRU"] = .init(payeeName: "Starbucks", templateName: "Coffee Shop")
    config.merchants["COFFEE BEAN & TEA"] = .init(payeeName: "Coffee Bean", templateName: "Coffee Shop")
    try? WalletTransactionConfigStore.save(config)

    return Color.backgroundColor
        .ignoresSafeArea()
        .sheet(isPresented: $isPresented) {
            NavigationStack {
                TemplateEditView(
                    templateName: "Coffee Shop",
                    onSave: { _ in },
                    onDelete: {}
                )
            }
        }
}
