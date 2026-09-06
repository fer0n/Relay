//
//  AddWalletTransactionToLedgerIntent.swift
//  Relay
//

import AppIntents
import os

private nonisolated let logger = Logger(subsystem: Const.loggerSubsystem, category: "WalletTransactionLedger")

struct AddWalletTransactionToLedgerIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Wallet Transaction to Ledger"
    static let description = IntentDescription(
        "Adds a shared iCloud ledger expense from a Wallet transaction, remembering split choices for next time."
    )

    @Parameter(title: "Merchant")
    var merchant: String

    @Parameter(title: "Amount")
    var amount: Double

    @Parameter(title: "Split Transaction?")
    var splitRuntimeChoice: SplitOption?

    @Parameter(title: "Split With")
    var splitTarget: SplitTargetEntity?

    @Parameter(title: "Your Share", description: "Only used when Split is Manual")
    var splitOwnShare: Double?

    @Parameter(title: "Source", description: "Distinguishes this automation from others firing for the same purchase, e.g. \"wallet\" vs. \"bank notification\". Leave blank for the Wallet automation.")
    var source: String?

    @Parameter(title: "Require Confirmation", description: "Never add to a ledger automatically. A purchase another automation already handled is skipped as usual; anything else is saved as a draft to approve in Relay.", default: false)
    var requireConfirmation: Bool

    @Parameter(title: "Ensure Completion", description: "If this run is interrupted before finishing, send a notification to continue it later.", default: true)
    var ensureCompletion: Bool

    @Parameter(title: "Success Notification", description: "When this action finishes successfully, send a confirmation notification.", default: true)
    var successNotification: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$amount) shared expense for \(\.$merchant)") {
            \.$splitRuntimeChoice
            \.$splitTarget
            \.$splitOwnShare
            \.$source
            \.$requireConfirmation
            \.$ensureCompletion
            \.$successNotification
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let claimSource = TransactionClaim.normalizedSource(source)
        logger.log("perform() start — merchant=\(merchant, privacy: .public) amount=\(amount, privacy: .public) source=\(claimSource, privacy: .public)")

        let claimId: UUID
        switch TransactionClaimStore.claimOrSuppress(
            TransactionClaim.Candidate(
                source: claimSource,
                destination: .ledger,
                amount: amount,
                accountId: nil,
                merchant: merchant,
                parksDraftOnly: requireConfirmation
            )
        ) {
        case .suppressed(let suppression):
            let dialog = WalletAutomationDialog.handleSuppression(suppression)
            logger.log("perform() done — suppressed as duplicate of \(suppression.matched.source, privacy: .public)")
            return .result(dialog: "\(dialog)")
        case .claimed(let id):
            claimId = id
        }

        if requireConfirmation {
            let dialog = WalletAutomationDialog.handleAwaitingSplitConfirmation(
                claimId,
                merchant: merchant,
                amount: amount,
                source: claimSource
            )
            logger.log("perform() done — nothing to confirm, left a draft to approve")
            return .result(dialog: "\(dialog)")
        }

        var claimResolved = false
        func commitClaim(historyEntryId: UUID?) {
            guard !claimResolved else { return }
            claimResolved = true
            WalletAutomationDialog.commitClaim(claimId, historyEntryId: historyEntryId)
        }

        let draftId = ensureCompletion
            ? TransactionDraftGuard.begin(.ledgerWallet(merchant: merchant, amount: amount))
            : nil

        func touchDraft() {
            if let draftId {
                TransactionDraftGuard.touch(draftId)
            }
        }

        func resolveTarget(
            existing: WalletTransactionConfig.CachedSplitTarget?,
            dialog: IntentDialog
        ) async throws -> WalletTransactionConfig.CachedSplitTarget {
            if let splitTarget {
                return splitTarget.cachedTarget
            }
            if let existing {
                return existing
            }
            if let fallback = DefaultSplitTargetStore.load() {
                logger.log("using app-wide default split target")
                return fallback
            }
            logger.log("requesting split target")
            let targets = try await SplitTargetEntity.defaultQuery.suggestedEntities()
            let picked = try await TransactionDraftGuard.withHeartbeat(draftId) {
                try await $splitTarget.requestDisambiguation(among: targets, dialog: dialog)
            }
            return picked.cachedTarget
        }

        do {
            await PendingOperationQueue.shared.flush()

            guard await SplitAvailability.canSplit else {
                logger.error("no shared ledger — nowhere to add the expense")
                throw LedgerExpenseError.notAvailable
            }

            var config = WalletTransactionConfigStore.load()
            var changed = false

            func persistConfig() {
                guard changed else { return }
                changed = false
                do {
                    try WalletTransactionConfigStore.save(config)
                    logger.log("config saved")
                } catch {
                    logger.error("failed to save config: \(String(describing: error), privacy: .public)")
                }
            }

            let expenseDescription: String
            let templateName: String

            if let info = config.resolvedMerchantInfo(for: merchant) {
                logger.log("merchant resolved to description=\(info.payeeName, privacy: .public) template=\(info.templateName, privacy: .public)")
                if config.merchants[merchant] == nil {
                    config.merchants[merchant] = info
                    changed = true
                }
                expenseDescription = info.payeeName
                templateName = info.templateName
            } else {
                templateName = config.ensureSplitDefaultTemplate()
                _ = config.linkMerchantIfChanged(merchant: merchant, payeeName: merchant, templateName: templateName)
                expenseDescription = merchant
                changed = true
            }

            let templateOption = config.templates[templateName]?.splitOption ?? .never

            persistConfig()

            let splitAction: SplitOption
            let target: WalletTransactionConfig.CachedSplitTarget?

            if templateOption == .never {
                splitAction = .never
                target = nil
            } else {
                let resolved = try await resolveTarget(
                    existing: config.templates[templateName]?.splitTarget,
                    dialog: IntentDialog(stringLiteral: String(format: String(localized: "Split %@ expenses with whom?"), templateName))
                )
                target = resolved
                if var template = config.templates[templateName], template.cacheSplitTargetIfMissing(resolved) {
                    config.templates[templateName] = template
                    changed = true
                    persistConfig()
                }

                switch templateOption {
                case .never:
                    splitAction = .never
                case .always:
                    splitAction = .always
                case .manual:
                    splitAction = .manual
                case .ask:
                    if let splitRuntimeChoice {
                        splitAction = splitRuntimeChoice
                    } else {
                        logger.log("splitOption=ask — requesting runtime choice")
                        splitAction = try await TransactionDraftGuard.askSplitChoice(
                            draftId: draftId,
                            context: TransactionDraft.PendingSplitContext(
                                description: expenseDescription,
                                target: SplitTargetEntity(cachedTarget: resolved)
                            )
                        ) {
                            let splitDescription = expenseDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                            let prompt: String
                            if splitDescription.isEmpty {
                                prompt = String(localized: "Split this transaction?")
                            } else {
                                prompt = String(format: String(localized: "Split this %@ transaction?"), splitDescription)
                            }
                            return try await $splitRuntimeChoice.requestValue(IntentDialog(stringLiteral: prompt))
                        }
                        touchDraft()
                    }
                }
            }

            let formattedAmount = amount.asMoneyString

            guard splitAction != .never, let target else {
                logger.log("splitAction=never — nothing to add")
                if let draftId {
                    TransactionDraftGuard.complete(draftId)
                }
                commitClaim(historyEntryId: nil)
                let dialog = WalletAutomationDialog.splitSkippedDialog(description: expenseDescription)
                if successNotification {
                    WalletCompletionNotification.postConfirmation(dialog: dialog)
                }
                logger.log("perform() done — not split")
                return .result(dialog: "\(dialog)")
            }

            var resolvedOwnShare: Double? = splitOwnShare
            if splitAction == .manual, resolvedOwnShare == nil {
                logger.log("splitAction=manual — requesting own share")
                let prompt = String(
                    format: String(localized: "Your share of the %@ expense at %@, split with %@?"),
                    formattedAmount,
                    expenseDescription,
                    target.firstName
                )
                resolvedOwnShare = try await TransactionDraftGuard.withHeartbeat(draftId) {
                    try await $splitOwnShare.requestValue(IntentDialog(stringLiteral: prompt))
                }
            }
            if splitAction == .manual, let resolvedOwnShare {
                try SplitExpenseService.validateOwnShare(resolvedOwnShare, amount: amount)
            }

            let outcome = try await SplitExpenseService.addExpense(
                amount: amount,
                description: expenseDescription,
                friend: SplitTargetEntity(cachedTarget: target),
                ownShare: (splitAction == .manual) ? resolvedOwnShare : nil,
                merchant: merchant
            )
            if let draftId {
                TransactionDraftGuard.complete(draftId)
            }
            let isQueued: Bool = if case .queued = outcome { true } else { false }
            commitClaim(historyEntryId: isQueued ? nil : TransactionHistoryStore.newestEntryID())

            let dialog = WalletAutomationDialog.ledgerWalletDialog(
                outcome: outcome,
                formattedAmount: formattedAmount,
                description: expenseDescription
            )
            if successNotification {
                let content = WalletAutomationDialog.notificationContent(
                    isQueued: isQueued,
                    formattedAmount: formattedAmount,
                    name: expenseDescription,
                    defaultTitle: String(localized: "Split Added"),
                    dialog: dialog
                )
                WalletCompletionNotification.postConfirmation(
                    title: content.title,
                    dialog: content.body,
                    historyEntryID: TransactionHistoryStore.newestEntryID()
                )
            }
            logger.log("perform() done — \(dialog, privacy: .public)")
            return .result(dialog: "\(dialog)")
        } catch {
            if let draftId {
                await TransactionDraftGuard.fail(draftId)
            }
            if !claimResolved {
                TransactionClaimStore.abandon(claimId)
            }
            throw error
        }
    }
}
