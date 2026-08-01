//
//  AddWalletTransactionToSplitwiseIntent.swift
//  Relay
//
//  Sibling to AddWalletTransactionToYNABIntent for a card used purely for
//  shared expenses: same Shortcuts "Transaction" automation and the same
//  WalletTransactionConfigStore, but it creates a Splitwise expense with no
//  YNAB transaction at all.
//
//  A Splitwise expense only needs a description + amount + split yes/no, so
//  unlike the YNAB intent this one never asks for template setup: an unknown
//  merchant is auto-filed under the default Splitwise template, described by
//  the merchant name, and only the split is asked. The friend is asked once
//  and written back onto the template rather than re-asked.
//
//  requestValue params must stay listed in parameterSummary — see the
//  equivalent note in AddWalletTransactionToYNABIntent.swift.
//

import AppIntents
import os

private nonisolated let logger = Logger(subsystem: Const.loggerSubsystem, category: "WalletTransactionSplitwise")

struct AddWalletTransactionToSplitwiseIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Wallet Transaction to Splitwise"
    static let description = IntentDescription(
        "Adds a Splitwise expense from a Wallet transaction, remembering friend/split choices for next time."
    )

    @Parameter(title: "Merchant")
    var merchant: String

    @Parameter(title: "Amount")
    var amount: Double

    /// Only used when the resolved template's split option is "Ask Each Time".
    @Parameter(title: "Split Transaction?")
    var splitwiseRuntimeChoice: SplitwiseSplitOption?

    /// Unset falls back to the template's cached friend, then the app-wide
    /// default; only a merchant with neither is asked live.
    @Parameter(title: "Split With")
    var friendOverride: SplitwiseFriendEntity?

    @Parameter(title: "Your Share", description: "Only used when Split is Manual")
    var splitwiseOwnShare: Double?

    /// See the equivalent parameter on AddWalletTransactionToYNABIntent.
    @Parameter(title: "Source", description: "Distinguishes this automation from others firing for the same purchase, e.g. \"wallet\" vs. \"bank notification\". Leave blank for the Wallet automation.")
    var source: String?

    /// See the equivalent parameter on AddWalletTransactionToYNABIntent. Kept for
    /// symmetry so both wallet automations wire up the same way, though a stray
    /// Splitwise expense is more visible and more easily deleted.
    @Parameter(title: "Require Confirmation", description: "Never add to Splitwise automatically. A purchase another automation already handled is skipped as usual; anything else is saved as a draft to approve in Relay.", default: false)
    var requireConfirmation: Bool

    /// See TransactionDraftGuard — a suspended perform() can't be resumed.
    @Parameter(title: "Ensure Completion", description: "If this run is interrupted before finishing, send a notification to continue it later.", default: true)
    var ensureCompletion: Bool

    @Parameter(title: "Success Notification", description: "When this action finishes successfully, send a confirmation notification.", default: true)
    var successNotification: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$amount) Splitwise expense for \(\.$merchant)") {
            \.$splitwiseRuntimeChoice
            \.$friendOverride
            \.$splitwiseOwnShare
            \.$source
            \.$requireConfirmation
            \.$ensureCompletion
            \.$successNotification
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let claimSource = TransactionClaim.normalizedSource(source)
        logger.log("perform() start — merchant=\(merchant, privacy: .public) amount=\(amount, privacy: .public) source=\(claimSource, privacy: .public)")

        // Ahead of the draft guard and any network call, so a purchase the other
        // automation already handled leaves no draft, reminder or API request.
        // No card parameter here, so `matches` has no account id to weigh in and
        // amount + time carry it.
        let claimId: UUID
        switch TransactionClaimStore.claimOrSuppress(
            TransactionClaim.Candidate(
                source: claimSource,
                destination: .splitwise,
                amount: amount,
                accountId: nil,
                merchant: merchant,
                // An unknown merchant auto-files under the default template, so
                // nothing but "Require Confirmation" can hold this run back.
                parksDraftOnly: requireConfirmation
            )
        ) {
        case .suppressed(let suppression):
            let dialog = WalletAutomationDialog.handleSuppression(suppression, successNotification: successNotification)
            logger.log("perform() done — suppressed as duplicate of \(suppression.matched.source, privacy: .public)")
            return .result(dialog: "\(dialog)")
        case .claimed(let id):
            claimId = id
        }

        // See the equivalent branch in AddWalletTransactionToYNABIntent for why
        // `ensureCompletion` isn't consulted. Which reminder the draft gets
        // depends on the template — see handleAwaitingSplitwiseConfirmation.
        if requireConfirmation {
            let dialog = WalletAutomationDialog.handleAwaitingSplitwiseConfirmation(
                claimId,
                merchant: merchant,
                amount: amount,
                source: claimSource
            )
            logger.log("perform() done — nothing to confirm, left a draft to approve")
            return .result(dialog: "\(dialog)")
        }

        // Unlike the YNAB intent nothing is committed ahead of the split — the
        // expense *is* the transaction — so this only fires at the very end.
        var claimResolved = false
        func commitClaim(historyEntryId: UUID?) {
            guard !claimResolved else { return }
            claimResolved = true
            WalletAutomationDialog.commitClaim(claimId, historyEntryId: historyEntryId)
        }

        let draftId = ensureCompletion
            ? TransactionDraftGuard.begin(.splitwiseWallet(merchant: merchant, amount: amount))
            : nil

        // Only for the split choice: the questions restore the quiet period
        // themselves (see withHeartbeat), but that one needs one more
        // rescheduling after its quick-reply actions are disarmed.
        func touchDraft() {
            if let draftId {
                TransactionDraftGuard.touch(draftId)
            }
        }

        // The shortcut parameter wins first, then the template's cached friend,
        // then the app-wide default, then ask live.
        func resolveFriend(existing: WalletTransactionConfig.CachedFriend?, dialog: IntentDialog) async throws -> WalletTransactionConfig.CachedFriend {
            if let friendOverride {
                return (friendOverride.id, friendOverride.firstName, friendOverride.fullName)
            }
            if let existing { return existing }
            let friend: SplitwiseFriendEntity
            if let defaultFriend = SplitwiseDefaultFriendStore.load() {
                logger.log("using app-wide default Splitwise friend")
                friend = SplitwiseFriendEntity(id: defaultFriend.id, firstName: defaultFriend.firstName, fullName: defaultFriend.fullName)
            } else {
                logger.log("requesting Splitwise friend")
                // Fetched outside the heartbeat — a slow call isn't an
                // interrupted run.
                let friends = try await SplitwiseFriendEntity.defaultQuery.suggestedEntities()
                friend = try await TransactionDraftGuard.withHeartbeat(draftId) {
                    try await $friendOverride.requestDisambiguation(
                        among: friends,
                        dialog: dialog
                    )
                }
            }
            return (friend.id, friend.firstName, friend.fullName)
        }

        do {
            await PendingOperationQueue.shared.flush()

            guard SplitwiseAuthService.currentAccessToken != nil else {
                logger.error("no Splitwise access token in Keychain — not authenticated")
                throw SplitwiseIntentError.notAuthenticated
            }

            var config = WalletTransactionConfigStore.load()
            var changed = false

            let expenseDescription: String
            let friendId: Int
            let friendFirstName: String
            let friendFullName: String
            let splitOption: SplitwiseTemplateOption

            if let info = config.resolvedMerchantInfo(for: merchant) {
                logger.log("merchant resolved to description=\(info.payeeName, privacy: .public) template=\(info.templateName, privacy: .public)")
                if config.merchants[merchant] == nil {
                    config.merchants[merchant] = info
                    changed = true
                }
                expenseDescription = info.payeeName
                let template = config.templates[info.templateName]
                splitOption = template?.splitwiseOption ?? .never

                let resolved = try await resolveFriend(
                    existing: template?.splitwiseFriend,
                    dialog: "Split \(info.templateName) expenses with which friend?"
                )
                friendId = resolved.id
                friendFirstName = resolved.firstName
                friendFullName = resolved.fullName
                // Backfill the friend when the template had none — e.g. it was
                // only ever used from the YNAB intent — so future runs don't ask.
                var updated = template ?? WalletTransactionConfig.Template()
                if updated.cacheSplitwiseFriendIfMissing(resolved) {
                    config.templates[info.templateName] = updated
                    changed = true
                }
            } else {
                // No stored mapping: auto-file under the default template rather
                // than walking the user through setup here. The description
                // defaults to the merchant name, and the split is still asked
                // because that template's option is `.ask`.
                let templateName = config.ensureSplitwiseDefaultTemplate()
                let template = config.templates[templateName]

                let resolvedFriend = try await resolveFriend(
                    existing: template?.splitwiseFriend,
                    dialog: IntentDialog(stringLiteral: String(format: String(localized: "Split %@ expenses with which friend?"), templateName))
                )

                // `changed` stays true regardless, since
                // ensureSplitwiseDefaultTemplate may have just created the
                // template.
                _ = config.recordSplitwiseMerchantLink(
                    merchant: merchant,
                    payeeName: merchant,
                    templateName: templateName,
                    friend: resolvedFriend
                )
                expenseDescription = merchant
                friendId = resolvedFriend.id
                friendFirstName = resolvedFriend.firstName
                friendFullName = resolvedFriend.fullName
                splitOption = config.templates[templateName]?.splitwiseOption ?? .never
                changed = true
            }

            // Persisted before the interruptible split question, so the mappings
            // survive a run that's finished from the notification instead.
            if changed {
                do {
                    try WalletTransactionConfigStore.save(config)
                    logger.log("config saved")
                } catch {
                    logger.error("failed to save config: \(String(describing: error), privacy: .public)")
                }
            }

            let splitwiseAction: SplitwiseSplitOption
            switch splitOption {
            case .never:
                splitwiseAction = .never
            case .always:
                splitwiseAction = .always
            case .manual:
                splitwiseAction = .manual
            case .ask:
                if let splitwiseRuntimeChoice {
                    splitwiseAction = splitwiseRuntimeChoice
                } else {
                    logger.log("splitOption=ask — requesting runtime choice")
                    // Description + friend are already resolved, so an
                    // interruption here can be answered from the reminder. With
                    // nothing committed ahead of the split, a dismiss defers (the
                    // draft stays) and Don't Split resolves it with no expense.
                    splitwiseAction = try await TransactionDraftGuard.askSplitChoice(
                        draftId: draftId,
                        context: TransactionDraft.PendingSplitContext(
                            description: expenseDescription,
                            friendId: friendId,
                            friendFirstName: friendFirstName,
                            friendFullName: friendFullName
                        )
                    ) {
                        let splitDescription = expenseDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                        let prompt: String
                        if splitDescription.isEmpty {
                            prompt = String(localized: "Split this transaction with Splitwise?")
                        } else {
                            prompt = String(format: String(localized: "Split this %@ transaction with Splitwise?"), splitDescription)
                        }
                        return try await $splitwiseRuntimeChoice.requestValue(IntentDialog(stringLiteral: prompt))
                    }
                    touchDraft()
                }
            }

            guard splitwiseAction != .never else {
                logger.log("splitwiseAction=never — skipping Splitwise")
                if let draftId {
                    TransactionDraftGuard.complete(draftId)
                }
                // Nothing written, but the purchase *has* been decided — commit
                // rather than abandon, so the other automation doesn't come back
                // and ask the same question. No entry to hang suppressions off.
                commitClaim(historyEntryId: nil)
                let dialog = WalletAutomationDialog.splitwiseSkippedDialog(description: expenseDescription)
                if successNotification {
                    WalletCompletionNotification.postConfirmation(dialog: dialog)
                }
                return .result(dialog: "\(dialog)")
            }

            var resolvedOwnShare: Double? = splitwiseOwnShare
            if splitwiseAction == .manual, resolvedOwnShare == nil {
                logger.log("splitwiseAction=manual — requesting own share")
                let formattedAmount = amount.asMoneyString
                let prompt = String(
                    format: String(localized: "Your share of the %@ expense at %@, split with %@?"),
                    formattedAmount,
                    expenseDescription,
                    friendFirstName
                )
                resolvedOwnShare = try await TransactionDraftGuard.withHeartbeat(draftId) {
                    try await $splitwiseOwnShare.requestValue(IntentDialog(stringLiteral: prompt))
                }
            }
            if splitwiseAction == .manual, let resolvedOwnShare {
                try SplitwiseExpenseHelper.validateOwnShare(resolvedOwnShare, amount: amount)
            }

            let formattedAmount = amount.asMoneyString
            do {
                let outcome = try await SplitwiseExpenseHelper.addExpense(
                    amount: amount,
                    description: expenseDescription,
                    friend: SplitwiseFriendEntity(id: friendId, firstName: friendFirstName, fullName: friendFullName),
                    ownShare: (splitwiseAction == .manual) ? resolvedOwnShare : nil,
                    merchant: merchant
                )
                if let draftId {
                    TransactionDraftGuard.complete(draftId)
                }
                let isQueued: Bool = if case .queued = outcome { true } else { false }
                // A queued expense records its entry only on sync, so
                // newestEntryID() would name an earlier, unrelated one.
                commitClaim(historyEntryId: isQueued ? nil : TransactionHistoryStore.newestEntryID())
                let dialog = WalletAutomationDialog.splitwiseWalletDialog(outcome: outcome, formattedAmount: formattedAmount, description: expenseDescription)
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
                logger.log("Splitwise result: \(dialog, privacy: .public)")
                return .result(dialog: "\(dialog)")
            } catch {
                logger.error("Splitwise addExpense failed: \(String(describing: error), privacy: .public)")
                // addExpense mostly throws a well-formed SplitwiseIntentError
                // already; `.from` only pattern-matches raw API errors, so
                // re-mapping would lose the specific reason.
                throw (error as? SplitwiseIntentError) ?? SplitwiseIntentError.from(error)
            }
        } catch {
            // No created/queued expense, so nudge right away rather than waiting
            // out the quiet-period window.
            if let draftId {
                await TransactionDraftGuard.fail(draftId)
            }
            // Nothing was written, so this run must stop shadowing the other
            // automation — its second sighting is the safety net for this case.
            if !claimResolved {
                TransactionClaimStore.abandon(claimId)
            }
            throw error
        }
    }
}
