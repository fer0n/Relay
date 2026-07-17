//
//  ContinueSplitwiseWalletTransactionView.swift
//  Hazel
//
//  In-app equivalent of AddWalletTransactionToSplitwiseIntent.perform(),
//  reached by tapping a "Continue Adding Transaction" notification (or a
//  draft row in TransactionDraftsView) after that Shortcuts run got
//  interrupted before finishing. Reads/writes the exact same
//  WalletTransactionConfigStore and calls the same SplitwiseExpenseHelper
//  the intent does — the only thing that differs is asking the remaining
//  questions via a SwiftUI form instead of requestValue/requestDisambiguation.
//
//  Unlike the intent, this doesn't replicate auto-match patterns or
//  multi-merchant template linking — creating a template here just links
//  this one merchant, using the description as the template name. Anything
//  fancier can still be set up afterwards in Templates.
//

import SwiftUI
import os

private let logger = Logger(subsystem: "com.pentlandFirth.Hazel", category: "ContinueSplitwiseWalletTransactionView")

struct ContinueSplitwiseWalletTransactionView: View {
    let draft: TransactionDraft

    @State private var notAuthenticated = false
    @State private var errorMessage: String?
    @State private var resultMessage: String?
    @State private var isSubmitting = false

    /// True once a merchant→template match is found — description/split
    /// setting are then fixed (read-only here) instead of asked again.
    @State private var templateResolved = false
    @State private var resolvedTemplateName: String?
    @State private var expenseDescription = ""

    /// True once the resolved (or matched) template already has a cached
    /// Splitwise friend — false also covers "no template yet", so the
    /// friend picker below is shown whenever this is false, regardless of
    /// `templateResolved`.
    @State private var templateHasFriend = false
    @State private var resolvedTemplateSplitOption: SplitwiseTemplateOption = .never

    @State private var friends: [SplitwiseFriend] = []
    @State private var selectedFriendId: Int?
    @State private var isLoadingFriends = false

    /// Only used/shown when `!templateResolved` — the split setting to save
    /// on the new template.
    @State private var newTemplateSplitOption: SplitwiseTemplateOption = .never

    @State private var splitwiseRuntimeChoice: SplitwiseSplitOption?
    @State private var ownShareText = ""

    /// Preview/testing seam only — nil (the default) always falls through
    /// to the real Keychain check. Lets `#Preview` render the form itself
    /// instead of the "Not Connected" gate.
    init(draft: TransactionDraft, isAuthenticatedOverride: Bool? = nil) {
        self.draft = draft

        // Resolved synchronously so the form is ready on the very first
        // render. `currentAccessToken` is a plain Keychain read here (no
        // network), unlike YNAB's token check, so even the auth gate can
        // be settled up front instead of behind a `.task`.
        guard case .splitwiseWallet(let merchant, _) = draft.payload else { return }

        let isAuthenticated = isAuthenticatedOverride ?? (SplitwiseAuthService.currentAccessToken != nil)
        guard isAuthenticated else {
            _notAuthenticated = State(initialValue: true)
            return
        }

        let config = WalletTransactionConfigStore.load()
        if let info = config.resolvedMerchantInfo(for: merchant) {
            _templateResolved = State(initialValue: true)
            _resolvedTemplateName = State(initialValue: info.templateName)
            _expenseDescription = State(initialValue: info.payeeName)
            let template = config.templates[info.templateName]
            _resolvedTemplateSplitOption = State(initialValue: template?.splitwiseOption ?? .never)
            if let friend = template?.splitwiseFriend {
                _templateHasFriend = State(initialValue: true)
                _selectedFriendId = State(initialValue: friend.id)
            }
        } else {
            _expenseDescription = State(initialValue: merchant)
        }
    }

    private var effectiveSplitOption: SplitwiseTemplateOption {
        templateResolved ? resolvedTemplateSplitOption : newTemplateSplitOption
    }

    private var resolvedSplitwiseAction: SplitwiseSplitOption {
        WalletAutomationDialog.resolvedSplitwiseAction(for: effectiveSplitOption, runtimeChoice: splitwiseRuntimeChoice)
    }

    private var canSubmit: Bool {
        if !templateResolved, expenseDescription.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        if !templateHasFriend, selectedFriendId == nil { return false }
        if effectiveSplitOption == .ask, splitwiseRuntimeChoice == nil { return false }
        if resolvedSplitwiseAction == .manual, Double(ownShareText) == nil { return false }
        return true
    }

    var body: some View {
        Group {
            if notAuthenticated {
                ContentUnavailableView(
                    "Not Connected",
                    systemImage: "exclamationmark.triangle",
                    description: Text("Connect your Splitwise account in Hazel first.")
                )
            } else if let resultMessage {
                ContentUnavailableView(
                    "Done",
                    systemImage: "person.2.fill",
                    description: Text(resultMessage)
                )
            } else {
                content
            }
        }
        .navigationTitle("Transaction draft")
        .task { await load() }
    }

    private var content: some View {
        List {
            Section {
                TransactionDraftHeader(amount: draft.formattedAmount, merchant: draft.merchant, startedAt: draft.startedAt)
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.backgroundColor)

            Section {
                DraftDetailRow(icon: "text.alignleft", title: "Description") {
                    if templateResolved {
                        Text(expenseDescription)
                    } else {
                        TextField("Description", text: $expenseDescription)
                            .multilineTextAlignment(.trailing)
                    }
                }
                .cardRowBackground()

                DraftDetailRow(icon: "doc.on.doc", title: "Template") {
                    Text(templateResolved ? (resolvedTemplateName ?? "Unknown") : "New")
                }
                .cardRowBackground()
            }

            Section("Split") {
                SplitwiseFriendPickerRow(
                    resolvedFriendName: templateHasFriend ? (friends.first { $0.id == selectedFriendId }?.fullName ?? "Unknown") : nil,
                    isLoading: isLoadingFriends,
                    friends: friends,
                    selectedFriendId: $selectedFriendId
                )

                SplitwiseOptionRow(
                    title: "Split",
                    isResolved: templateResolved,
                    resolvedOption: resolvedTemplateSplitOption,
                    newOption: $newTemplateSplitOption
                )

                if effectiveSplitOption == .ask {
                    SplitwiseAskRow(runtimeChoice: $splitwiseRuntimeChoice)
                }

                if resolvedSplitwiseAction == .manual {
                    SplitwiseOwnShareRow(ownShareText: $ownShareText)
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
                .listRowBackground(Color.backgroundColor)
            }
        }
        .themedList(background: .backgroundColor)
        .safeAreaBar(edge: .bottom) {
            Button {
                Task { await submit() }
            } label: {
                if isSubmitting {
                    ProgressView()
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                } else {
                    Text("Add Expense")
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .themedText()
                }
            }
            .buttonStyle(.glassProminent)
            .foregroundStyle(Color.accentColor)
            .disabled(!canSubmit || isSubmitting)
        }
    }

    private func load() async {
        guard !notAuthenticated else { return }
        await loadFriends()
    }

    private func loadFriends() async {
        guard !templateHasFriend else { return }
        guard let token = SplitwiseAuthService.currentAccessToken else { return }
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

    private func submit() async {
        guard case .splitwiseWallet(let merchant, let amount) = draft.payload else { return }
        guard SplitwiseAuthService.currentAccessToken != nil else {
            notAuthenticated = true
            return
        }
        errorMessage = nil
        isSubmitting = true
        defer { isSubmitting = false }

        var config = WalletTransactionConfigStore.load()
        var configChanged = false

        let finalDescription: String
        if templateResolved {
            finalDescription = expenseDescription
        } else {
            let trimmed = expenseDescription.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                errorMessage = "Description can't be empty."
                return
            }
            finalDescription = trimmed
        }

        let finalFriendId: Int
        let finalFriendFirstName: String
        let finalFriendFullName: String
        if templateHasFriend, let templateName = resolvedTemplateName, let existing = config.templates[templateName]?.splitwiseFriend {
            finalFriendId = existing.id
            finalFriendFirstName = existing.firstName
            finalFriendFullName = existing.fullName
        } else {
            guard let selectedFriendId, let match = friends.first(where: { $0.id == selectedFriendId }) else {
                errorMessage = "Pick a Splitwise friend."
                return
            }
            finalFriendId = match.id
            finalFriendFirstName = match.firstName
            finalFriendFullName = match.fullName
        }

        if templateResolved, let templateName = resolvedTemplateName {
            if !templateHasFriend {
                var template = config.templates[templateName] ?? WalletTransactionConfig.Template()
                template.splitwiseFriendId = finalFriendId
                template.splitwiseFriendFirstName = finalFriendFirstName
                template.splitwiseFriendFullName = finalFriendFullName
                config.templates[templateName] = template
                configChanged = true
            }
        } else {
            var template = config.templates[finalDescription] ?? WalletTransactionConfig.Template()
            template.splitwiseFriendId = finalFriendId
            template.splitwiseFriendFirstName = finalFriendFirstName
            template.splitwiseFriendFullName = finalFriendFullName
            template.splitwiseOption = newTemplateSplitOption
            config.templates[finalDescription] = template
            config.merchants[merchant] = WalletTransactionConfig.MerchantInfo(payeeName: finalDescription, templateName: finalDescription)
            configChanged = true
        }

        if configChanged {
            do {
                try WalletTransactionConfigStore.save(config)
            } catch {
                logger.error("failed to save config: \(String(describing: error), privacy: .public)")
            }
        }

        let action = resolvedSplitwiseAction
        guard action != .never else {
            TransactionDraftGuard.complete(draft.id)
            resultMessage = WalletAutomationDialog.splitwiseSkippedDialog(description: finalDescription)
            return
        }

        var ownShare: Double?
        if action == .manual {
            guard let parsed = Double(ownShareText) else {
                errorMessage = "Enter a valid share amount."
                return
            }
            do {
                try SplitwiseExpenseHelper.validateOwnShare(parsed, amount: amount)
            } catch {
                errorMessage = (error as? SplitwiseIntentError).map { String(localized: $0.localizedStringResource) } ?? "Invalid share amount."
                return
            }
            ownShare = parsed
        }

        let formattedAmount = amount.asMoneyString
        do {
            let outcome = try await SplitwiseExpenseHelper.addExpense(
                amount: amount,
                description: finalDescription,
                friend: SplitwiseFriendEntity(id: finalFriendId, firstName: finalFriendFirstName, fullName: finalFriendFullName),
                ownShare: ownShare
            )
            TransactionDraftGuard.complete(draft.id)
            resultMessage = WalletAutomationDialog.splitwiseWalletDialog(outcome: outcome, formattedAmount: formattedAmount, description: finalDescription)
        } catch {
            errorMessage = (error as? SplitwiseIntentError).map { String(localized: $0.localizedStringResource) } ?? "Couldn't add the Splitwise expense."
        }
    }
}

#Preview {
    NavigationStack {
        ContinueSplitwiseWalletTransactionView(
            draft: TransactionDraft(
                id: UUID(),
                startedAt: Date().addingTimeInterval(-3600),
                payload: .splitwiseWallet(merchant: "Grocery Store", amount: 32.10)
            ),
            isAuthenticatedOverride: true
        )
    }
}
