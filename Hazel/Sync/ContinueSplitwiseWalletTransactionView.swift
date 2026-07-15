//
//  ContinueSplitwiseWalletTransactionView.swift
//  Hazel
//
//  In-app equivalent of AddWalletTransactionToSplitwiseIntent.perform(),
//  reached by tapping a "Continue Adding Transaction" notification (or a
//  draft row in TransactionDraftsView) after that Shortcuts run got
//  interrupted before finishing. Reads/writes the exact same
//  SplitwiseWalletTransactionConfigStore and calls the same
//  SplitwiseExpenseHelper the intent does — the only thing that differs is
//  asking the remaining questions via a SwiftUI form instead of
//  requestValue/requestDisambiguation.
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

    @State private var isLoading = true
    @State private var notAuthenticated = false
    @State private var errorMessage: String?
    @State private var resultMessage: String?
    @State private var isSubmitting = false

    /// True once a merchant→template match is found — description/friend/
    /// split setting are then fixed (read-only here) instead of asked again.
    @State private var templateResolved = false
    @State private var expenseDescription = ""

    @State private var resolvedFriendId = 0
    @State private var resolvedFriendFirstName = ""
    @State private var resolvedFriendFullName = ""
    @State private var resolvedTemplateSplitOption: SplitwiseTemplateOption = .never

    @State private var friends: [SplitwiseFriend] = []
    @State private var selectedFriendId: Int?
    @State private var isLoadingFriends = false

    /// Only used/shown when `!templateResolved` — the split setting to save
    /// on the new template.
    @State private var newTemplateSplitOption: SplitwiseTemplateOption = .never

    @State private var splitwiseRuntimeChoice: SplitwiseSplitOption?
    @State private var ownShareText = ""

    private var effectiveSplitOption: SplitwiseTemplateOption {
        templateResolved ? resolvedTemplateSplitOption : newTemplateSplitOption
    }

    private var resolvedSplitwiseAction: SplitwiseSplitOption {
        WalletAutomationDialog.resolvedSplitwiseAction(for: effectiveSplitOption, runtimeChoice: splitwiseRuntimeChoice)
    }

    private var canSubmit: Bool {
        if !templateResolved {
            if expenseDescription.trimmingCharacters(in: .whitespaces).isEmpty { return false }
            if selectedFriendId == nil { return false }
        }
        if effectiveSplitOption == .ask, splitwiseRuntimeChoice == nil { return false }
        if resolvedSplitwiseAction == .manual, Double(ownShareText) == nil { return false }
        return true
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
            } else if notAuthenticated {
                ContentUnavailableView(
                    "Not Connected",
                    systemImage: "exclamationmark.triangle",
                    description: Text("Connect your Splitwise account in Hazel first.")
                )
            } else if let resultMessage {
                ContentUnavailableView(
                    "Done",
                    systemImage: "checkmark.circle",
                    description: Text(resultMessage)
                )
            } else {
                form
            }
        }
        .navigationTitle("Continue Expense")
        .task { await load() }
    }

    private var form: some View {
        Form {
            Section {
                Text(draft.summary).font(.headline)
                Text("Started \(RelativeDateTimeFormatter().localizedString(for: draft.startedAt, relativeTo: Date()))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if templateResolved {
                Section("Resolved From Template") {
                    LabeledContent("Description", value: expenseDescription)
                    LabeledContent("Split With", value: resolvedFriendFullName)
                }
            } else {
                Section("Description") {
                    TextField("Description", text: $expenseDescription)
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
            }

            Section("Splitwise") {
                if templateResolved {
                    LabeledContent("Split Setting", value: resolvedTemplateSplitOption.label)
                } else {
                    Picker("Split", selection: $newTemplateSplitOption) {
                        ForEach([SplitwiseTemplateOption.ask, .always, .manual, .never], id: \.self) { option in
                            Text(option.label).tag(option)
                        }
                    }
                }

                if effectiveSplitOption == .ask {
                    Picker("Split This Transaction?", selection: $splitwiseRuntimeChoice) {
                        Text("Choose").tag(SplitwiseSplitOption?.none)
                        ForEach([SplitwiseSplitOption.always, .manual, .never], id: \.self) { option in
                            Text(option.label).tag(SplitwiseSplitOption?.some(option))
                        }
                    }
                }

                if resolvedSplitwiseAction == .manual {
                    TextField("Your Share", text: $ownShareText)
                        .keyboardType(.decimalPad)
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    Task { await submit() }
                } label: {
                    if isSubmitting {
                        ProgressView()
                    } else {
                        Text("Add Expense")
                    }
                }
                .disabled(!canSubmit || isSubmitting)
            }
        }
        // Menu-style pickers show their value in the same secondary gray as
        // read-only LabeledContent rows, with only a tiny chevron.up.chevron.down
        // glyph to tell them apart — easy to miss. A navigation chevron is a
        // much clearer "this is tappable" signal.
        .pickerStyle(.navigationLink)
    }

    private func load() async {
        guard case .splitwiseWallet(let merchant, _) = draft.payload else { return }

        guard SplitwiseAuthService.currentAccessToken != nil else {
            notAuthenticated = true
            isLoading = false
            return
        }

        let config = SplitwiseWalletTransactionConfigStore.load()
        if let info = config.resolvedMerchantInfo(for: merchant) {
            templateResolved = true
            expenseDescription = info.expenseDescription
            let template = config.templates[info.templateName]
            resolvedFriendId = template?.friendId ?? 0
            resolvedFriendFirstName = template?.friendFirstName ?? ""
            resolvedFriendFullName = template?.friendFullName ?? ""
            resolvedTemplateSplitOption = template?.splitOption ?? .never
        } else {
            expenseDescription = merchant
        }

        await loadFriends()
        isLoading = false
    }

    private func loadFriends() async {
        guard !templateResolved else { return }
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

        var config = SplitwiseWalletTransactionConfigStore.load()
        var configChanged = false
        let finalDescription: String
        let finalFriendId: Int
        let finalFriendFirstName: String
        let finalFriendFullName: String

        if templateResolved {
            finalDescription = expenseDescription
            finalFriendId = resolvedFriendId
            finalFriendFirstName = resolvedFriendFirstName
            finalFriendFullName = resolvedFriendFullName
        } else {
            let trimmed = expenseDescription.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                errorMessage = "Description can't be empty."
                return
            }
            guard let selectedFriendId, let match = friends.first(where: { $0.id == selectedFriendId }) else {
                errorMessage = "Pick a Splitwise friend."
                return
            }
            var template = config.templates[trimmed] ?? SplitwiseWalletTransactionConfig.Template(
                friendId: match.id,
                friendFirstName: match.firstName,
                friendFullName: match.fullName
            )
            template.friendId = match.id
            template.friendFirstName = match.firstName
            template.friendFullName = match.fullName
            template.splitOption = newTemplateSplitOption
            config.templates[trimmed] = template
            config.merchants[merchant] = SplitwiseWalletTransactionConfig.MerchantInfo(expenseDescription: trimmed, templateName: trimmed)
            finalDescription = trimmed
            finalFriendId = match.id
            finalFriendFirstName = match.firstName
            finalFriendFullName = match.fullName
            configChanged = true
        }

        if configChanged {
            do {
                try SplitwiseWalletTransactionConfigStore.save(config)
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

        let formattedAmount = amount.formatted(.number.precision(.fractionLength(2)))
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
