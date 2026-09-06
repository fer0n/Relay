//
//  WalletAutomationDialog.swift
//  Relay
//
//  Shared "what actually happened, in words" logic for the wallet automations.
//  The Shortcuts intents and their in-app resume counterpart ask their
//  remaining questions completely differently, but everything from the outcome
//  onward is identical, so it lives here rather than drifting apart.
//

import AppIntents
import Foundation

nonisolated extension SplitOption {
    /// Plain-text label for Relay's own SwiftUI screens — mirrors
    /// SplitTemplateOption.label in TemplatesView.swift.
    var label: String {
        String(localized: Self.caseDisplayRepresentations[self]?.title ?? "")
    }
}

nonisolated enum WalletAutomationDialog {
    /// Only used by the Continue views, whose bound state already holds the "ask
    /// each time" answer. The intents resolve `.ask` via a requestValue side
    /// effect instead and don't route through here.
    static func resolvedSplitAction(
        for templateOption: SplitTemplateOption,
        runtimeChoice: SplitOption?
    ) -> SplitOption {
        switch templateOption {
        case .never: .never
        case .always: .always
        case .manual: .manual
        case .ask: runtimeChoice ?? .never
        }
    }

    /// Never throws: the YNAB write already succeeded or queued by the time this
    /// is worth calling, so a split failure is only a note in the dialog.
    ///
    /// `merchant` must be the same string the YNAB half was recorded with — the
    /// two writes fold into one history entry, and under `async let` whichever
    /// lands first sets its `merchant`.
    static func splitDialogFragment(
        amount: Double,
        description: String,
        friend: SplitTargetEntity,
        ownShare: Double?,
        groupId: UUID? = nil,
        merchant: String? = nil
    ) async -> (fragment: String, isQueued: Bool) {
        // Goes through the entity-taking entry point rather than building a
        // target here: a picked entity can be a group or a ledger, whose
        // membership has to be looked up. Constructing a one-person target
        // from the entity directly would bill the *container's* id as if it
        // were a person.
        await run {
            try await SplitExpenseService.addExpense(
                amount: amount,
                description: description,
                friend: friend,
                ownShare: ownShare,
                groupId: groupId,
                merchant: merchant
            )
        }
    }

    /// The multi-participant form, used by the in-app forms — their picker can
    /// name several people or a whole container, which the Shortcuts-facing
    /// single-target parameters above can't express.
    static func splitDialogFragment(
        amount: Double,
        description: String,
        target: SplitTarget,
        allocation: SplitAllocation,
        groupId: UUID? = nil,
        merchant: String? = nil
    ) async -> (fragment: String, isQueued: Bool) {
        await run {
            try await SplitExpenseService.addExpense(
                amount: amount,
                description: description,
                target: target,
                allocation: allocation,
                groupId: groupId,
                merchant: merchant
            )
        }
    }

    /// Turns either entry point's outcome into the dialog's trailing fragment.
    private static func run(
        _ create: () async throws -> SplitExpenseOutcome
    ) async -> (fragment: String, isQueued: Bool) {
        do {
            let outcome = try await create()
            switch outcome {
            case .created(let shareSummary):
                return (" – \(shareSummary)", false)
            case .queued:
                return (" – \(String(localized: "split queued for sync"))", true)
            }
        } catch let error as LedgerExpenseError {
            // Its own message — "sign in to iCloud" is the useful thing to say
            // when that's what went wrong.
            return (" – \(error.localizedDescription)", false)
        } catch {
            return (" – \(String(localized: "Couldn't add the split."))", false)
        }
    }

    /// Once anything queued, the notification leads with the amount/name as its
    /// title so the banner doesn't read like a completed "Added" while offline.
    /// Siri's spoken `dialog` keeps the fuller wording either way.
    static func notificationContent(
        isQueued: Bool,
        formattedAmount: String,
        name: String,
        defaultTitle: String,
        dialog: String
    ) -> (title: String, body: String) {
        guard isQueued else { return (defaultTitle, dialog) }
        return (
            String(localized: "\(formattedAmount) at \(name)"),
            String(localized: "No connection, but added locally. Waiting to sync.")
        )
    }

    /// Finishes off a run that duplicates a purchase the other automation already
    /// added (see TransactionClaim). Posts nothing: the run that claimed the
    /// purchase owns its one notification.
    static func handleSuppression(_ suppression: TransactionClaimStore.Suppression) -> String {
        let matched = suppression.matched
        // While the matched run is still in flight its suppressions ride along on
        // the claim instead, and it folds them in when it commits.
        if let historyEntryId = suppression.historyEntryId {
            TransactionHistoryStore.recordSuppressions([suppression.run], on: historyEntryId)
        }

        // "Handled" rather than "added": a suppressed run doesn't always shadow a
        // written transaction — on the split-only path a deliberate "Don't
        // Split" also claims the purchase.
        let dialog = String(
            format: String(localized: "%@ at %@ was already handled by \"%@\" %@ – skipped."),
            suppression.run.amount.asMoneyString,
            matched.merchant,
            matched.source,
            matched.claimedAt.formatted(.relative(presentation: .numeric))
        )

        return dialog
    }

    /// Marks a claim as written and applies what that costs the rest of the
    /// ledger: suppressed runs land on the new entry, and any draft left by a
    /// confirmation-only sighting is cleared.
    ///
    /// `historyEntryId` is nil when the write only queued — the entry is recorded
    /// on sync, so there's nothing to annotate yet. The superseded drafts still
    /// go, because the transaction is on its way regardless.
    static func commitClaim(_ claimId: UUID, historyEntryId: UUID?) {
        let result = TransactionClaimStore.commit(claimId, historyEntryId: historyEntryId)
        if let historyEntryId {
            TransactionHistoryStore.recordSuppressions(result.suppressed, on: historyEntryId)
        }
        for draftId in result.supersededDraftIds {
            TransactionDraftGuard.complete(draftId)
        }
    }

    /// Finishes off a confirm-only run that found nothing to confirm: the
    /// purchase is parked as a draft, and the claim records it so a later real
    /// write can clear it.
    ///
    /// No "success notification" gate — the reminder isn't a courtesy ping, it's
    /// the only prompt for the approval this parameter exists to require. (It
    /// still respects the app-wide switch, via TransactionDraftGuard.)
    static func handleAwaitingConfirmation(
        _ claimId: UUID,
        payload: TransactionDraft.Payload,
        source: String
    ) -> String {
        let draftId = TransactionDraftGuard.beginAwaitingConfirmation(payload, source: source)
        TransactionClaimStore.awaitConfirmation(claimId, draftId: draftId)
        return String(
            format: String(localized: "%@ at %@ needs confirmation – waiting in Relay."),
            payload.amount.asMoneyString,
            payload.merchant
        )
    }

    /// Finishes off a run that stopped because its merchant has no template. Same
    /// bookkeeping as `handleAwaitingConfirmation`, since both are sightings that
    /// deliberately added nothing.
    ///
    /// `draftId` is the draft the run's "Ensure Completion" guard already began,
    /// reused rather than starting a second one. Returned alongside the dialog so
    /// the caller can jump straight into it (see `continueInForeground`) rather
    /// than leaving the reminder as the only way back.
    static func handleNeedsTemplate(
        _ claimId: UUID,
        payload: TransactionDraft.Payload,
        draftId: UUID?
    ) -> (dialog: String, draftId: UUID) {
        let resolvedDraftId = TransactionDraftGuard.beginNeedsTemplate(payload, existing: draftId)
        TransactionClaimStore.awaitConfirmation(claimId, draftId: resolvedDraftId)
        let dialog = String(
            format: String(localized: "%@ at %@ needs a template – waiting in Relay."),
            payload.amount.asMoneyString,
            payload.merchant
        )
        return (dialog, resolvedDraftId)
    }

    /// The split flavour of `handleAwaitingConfirmation`.
    ///
    /// Under "Ask Each Time" the split question already *is* a confirmation: the
    /// expense is the whole transaction here, so "Don't Split" does what Discard
    /// would. Asking both would be two questions about one purchase, so the draft
    /// goes straight to the split-choice reminder. Everything else gets the
    /// ordinary Add/Discard reminder, having no second question to stand in.
    static func handleAwaitingSplitConfirmation(
        _ claimId: UUID,
        merchant: String,
        amount: Double,
        source: String
    ) -> String {
        let payload = TransactionDraft.Payload.ledgerWallet(merchant: merchant, amount: amount)
        let config = WalletTransactionConfigStore.load()
        let info = config.resolvedMerchantInfo(for: merchant)
        let template = info.flatMap { config.templates[$0.templateName] }

        guard template?.splitOption == .ask, SplitAvailability.hasKnownSharedLedger else {
            return handleAwaitingConfirmation(claimId, payload: payload, source: source)
        }

        // A nil friend is allowed through: "Don't Split" still resolves the draft
        // without one, and the other answers land on the same finish-in-app nudge
        // they would anyway (see WalletDraftCompletion).
        let description = info?.payeeName ?? merchant
        let friend = friendWithoutAsking(template: template)
        let draftId = TransactionDraftGuard.beginAwaitingSplitChoice(
            payload,
            context: TransactionDraft.PendingSplitContext(description: description, target: friend)
        )
        TransactionClaimStore.awaitConfirmation(claimId, draftId: draftId)
        return String(
            format: String(localized: "%@ at %@ – waiting on your split choice."),
            amount.asMoneyString,
            description
        )
    }

    /// Nil means the question genuinely can't be answered without asking.
    static func friendWithoutAsking(template: WalletTransactionConfig.Template?) -> SplitTargetEntity? {
        if let cached = template?.splitTarget {
            return SplitTargetEntity(cachedTarget: cached)
        }
        return DefaultSplitTargetStore.load().map { SplitTargetEntity(cachedTarget: $0) }
    }

    /// Also records category usage on success.
    static func handleYNABOutcome(
        _ outcome: PendingSyncOutcome,
        formattedAmount: String,
        payeeName: String,
        categoryId: String?
    ) -> String {
        switch outcome {
        case .created:
            if let categoryId {
                YNABCategoryUsageStore.recordUsage(categoryId: categoryId)
            }
            return String(localized: "\(formattedAmount) at \(payeeName)")
        case .queued:
            return String(localized: "No connection – \(formattedAmount) at \(payeeName) – queued for sync")
        }
    }

    /// Distinct from the standalone AddLedgerExpenseIntent, which deliberately
    /// omits the amount from its own wording.
    static func ledgerWalletDialog(
        outcome: SplitExpenseOutcome,
        formattedAmount: String,
        description: String
    ) -> String {
        switch outcome {
        case .created(let shareSummary):
            String(localized: "\(formattedAmount) at \(description) – \(shareSummary)")
        case .queued:
            String(localized: "No connection – \(formattedAmount) at \(description) – queued for sync")
        }
    }

    static func splitSkippedDialog(description: String) -> String {
        String(localized: "Skipping \(description) — merchant is set to not split.")
    }
}
