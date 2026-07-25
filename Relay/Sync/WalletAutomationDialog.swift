//
//  WalletAutomationDialog.swift
//  Relay
//
//  Shared "what actually happened, in words" logic for the wallet
//  automations — used identically by the Shortcuts intents
//  (AddYNABTransactionIntent, AddWalletTransactionToYNABIntent,
//  AddWalletTransactionToSplitwiseIntent) and their in-app resume
//  counterpart (ContinueWalletTransactionView). The two entry points ask their
//  remaining questions completely differently (requestValue/
//  requestDisambiguation vs. a SwiftUI form), but everything from "here's
//  what to say about the outcome" onward was byte-for-byte duplicated
//  across up to three files — pulled out here so a wording or behavior fix
//  only has to happen once instead of drifting apart between call sites.
//

import AppIntents
import Foundation

extension SplitwiseSplitOption {
    /// Plain-text label for Relay's own SwiftUI screens, derived from
    /// `caseDisplayRepresentations` — mirrors SplitwiseTemplateOption.label
    /// in TemplatesView.swift.
    var label: String {
        String(localized: Self.caseDisplayRepresentations[self]?.title ?? "")
    }
}

nonisolated enum WalletAutomationDialog {
    /// Maps a template's stored Splitwise setting to a concrete per-run
    /// action, given a live "ask each time" answer if one's already in
    /// hand. Only used by the Continue views: their form's bound state
    /// already holds the answer (or a not-yet-chosen nil while the submit
    /// button stays disabled), unlike the intents, which resolve "ask" via
    /// a genuine requestValue side effect and so don't route through this.
    static func resolvedSplitwiseAction(
        for templateOption: SplitwiseTemplateOption,
        runtimeChoice: SplitwiseSplitOption?
    ) -> SplitwiseSplitOption {
        switch templateOption {
        case .never: .never
        case .always: .always
        case .manual: .manual
        case .ask: runtimeChoice ?? .never
        }
    }

    /// Attempts the Splitwise half of a YNAB-primary transaction and
    /// describes the result as a dialog fragment to append. Never throws:
    /// a Splitwise failure only ever shows up as a note in the dialog, it
    /// never fails the whole run — the YNAB write already succeeded or
    /// queued by the time this is worth calling.
    static func splitDialogFragment(
        amount: Double,
        description: String,
        friend: SplitwiseFriendEntity,
        ownShare: Double?,
        groupId: UUID? = nil
    ) async -> (fragment: String, isQueued: Bool) {
        do {
            let outcome = try await SplitwiseExpenseHelper.addExpense(
                amount: amount,
                description: description,
                friend: friend,
                ownShare: ownShare,
                groupId: groupId
            )
            switch outcome {
            case .created(let shareSummary):
                return (" – \(shareSummary)", false)
            case .queued:
                return (" – split queued for sync", true)
            }
        } catch {
            let message = (error as? SplitwiseIntentError)?.localizedStringResource
                ?? "Couldn't add the Splitwise expense."
            return (" – \(String(localized: message))", false)
        }
    }

    /// Notification title/body for a wallet automation's outcome. Siri's
    /// spoken result (`dialog`) keeps the fuller "$5.00 at Marktkauf – queued
    /// for sync" wording regardless of outcome; the notification instead
    /// leads with the amount/name as its title once anything queued, so the
    /// banner doesn't read like a completed "Added" while still offline.
    static func notificationContent(
        isQueued: Bool,
        formattedAmount: String,
        name: String,
        defaultTitle: String,
        dialog: String
    ) -> (title: String, body: String) {
        guard isQueued else { return (defaultTitle, dialog) }
        return (
            "\(formattedAmount) at \(name)",
            String(localized: "No connection, but added locally. Waiting to sync.")
        )
    }

    /// Finishes off a run that turned out to be a purchase already added
    /// through the other automation (see TransactionClaim): annotates the
    /// entry it duplicates, optionally says so, and returns the dialog for
    /// Shortcuts. Shared by both wallet intents, which reach this in exactly
    /// the same way.
    ///
    /// The suppressed run leaves no draft and no reminder — that's the whole
    /// point of dropping it — so this notification is the only trace the
    /// user sees in the moment. It's still gated on the automation's
    /// "Success Notification" switch: that switch is the user's "stop
    /// buzzing me" control, and with both automations wired up a duplicate
    /// arrives for nearly every purchase, so ignoring it here would be the
    /// noisiest possible reading of it.
    static func handleSuppression(
        _ suppression: TransactionClaimStore.Suppression,
        successNotification: Bool
    ) -> String {
        let matched = suppression.matched
        // Only when the run this duplicates has already recorded something.
        // While it's still in flight its suppressions ride along on the
        // claim instead, and it folds them in when it commits.
        if let historyEntryId = suppression.historyEntryId {
            TransactionHistoryStore.recordSuppressions([suppression.run], on: historyEntryId)
        }

        // "Handled" rather than "added" because a suppressed run doesn't
        // always shadow a written transaction: on the Splitwise-only path a
        // deliberate "Don't Split" also claims the purchase, so that the
        // second automation doesn't ask the same question over again. It has
        // decided the purchase either way, which is what the user needs to
        // know here.
        let dialog = String(
            format: String(localized: "%@ at %@ was already handled by \"%@\" %@ – skipped."),
            suppression.run.amount.asMoneyString,
            matched.merchant,
            matched.source,
            matched.claimedAt.formatted(.relative(presentation: .numeric))
        )

        if successNotification {
            WalletCompletionNotification.postConfirmation(
                title: String(localized: "Duplicate Skipped"),
                dialog: dialog,
                historyEntryID: suppression.historyEntryId
            )
        }
        return dialog
    }

    /// Marks a run's claim as having written its transaction, and applies
    /// what that costs the rest of the ledger: the runs suppressed against it
    /// are recorded on the entry it just created, and any draft left by a
    /// confirmation-only sighting of the same purchase is cleared, since the
    /// transaction it was asking about now exists.
    ///
    /// `historyEntryId` is nil when the write only *queued* — the entry is
    /// recorded on sync, so there's nothing to annotate yet. The superseded
    /// drafts still go, because the transaction is on its way regardless.
    static func commitClaim(_ claimId: UUID, historyEntryId: UUID?) {
        let result = TransactionClaimStore.commit(claimId, historyEntryId: historyEntryId)
        if let historyEntryId {
            TransactionHistoryStore.recordSuppressions(result.suppressed, on: historyEntryId)
        }
        for draftId in result.supersededDraftIds {
            TransactionDraftGuard.complete(draftId)
        }
    }

    /// Finishes off a run whose automation requires confirmation and that
    /// found nothing to confirm: nothing is written, the purchase is parked
    /// as a draft, and the claim records the draft so a later real write can
    /// clear it. Returns the dialog for Shortcuts.
    ///
    /// No "success notification" gate here — the draft reminder isn't a
    /// courtesy ping about something that already happened, it's the only
    /// prompt for the approval the whole parameter exists to require. It
    /// still respects the app-wide notifications switch, via
    /// TransactionDraftGuard.
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

    /// Finishes off a run that stopped because the merchant it was handed has
    /// no template to file it under: nothing is written, the purchase is
    /// parked as a draft, and the claim records it so a later run that does
    /// write clears it (same bookkeeping as an awaiting-confirmation draft —
    /// see `handleAwaitingConfirmation` — since both are sightings that
    /// deliberately added nothing).
    ///
    /// `draftId` is the draft the run's "Ensure Completion" guard already
    /// began, if any; the same one is reused rather than a second one started.
    ///
    /// No "success notification" gate, for the same reason as
    /// `handleAwaitingConfirmation`: the reminder isn't a courtesy ping about
    /// something that happened, it's the prompt telling the user the
    /// transaction is sitting in Relay waiting on them.
    ///
    /// Returns the draft's id alongside the dialog so the caller can offer to
    /// jump straight into it (see the intent's `continueInForeground` call)
    /// rather than leaving the reminder as the only way back.
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

    /// The Splitwise flavour of `handleAwaitingConfirmation`.
    ///
    /// When the merchant's template is set to "Ask Each Time", the split
    /// question already *is* a confirmation: on this path the expense is the
    /// whole transaction, so "Don't Split" means nothing gets created at all
    /// — exactly what Discard would do. Asking "Add or Discard?" first would
    /// just make the user answer two questions in a row about one purchase,
    /// so the draft goes straight to the split-choice reminder.
    ///
    /// Everything else still gets the ordinary Add/Discard reminder: a
    /// template with a fixed split setting, an unknown merchant, or a
    /// disconnected Splitwise account all mean no second question is coming
    /// that could stand in for the confirmation.
    static func handleAwaitingSplitwiseConfirmation(
        _ claimId: UUID,
        merchant: String,
        amount: Double,
        source: String
    ) -> String {
        let payload = TransactionDraft.Payload.splitwiseWallet(merchant: merchant, amount: amount)
        let config = WalletTransactionConfigStore.load()
        let info = config.resolvedMerchantInfo(for: merchant)
        let template = info.flatMap { config.templates[$0.templateName] }

        guard template?.splitwiseOption == .ask, SplitwiseAuthService.currentAccessToken != nil else {
            return handleAwaitingConfirmation(claimId, payload: payload, source: source)
        }

        // A nil friend is allowed through rather than falling back to
        // Add/Discard: "Don't Split" still resolves the draft without one,
        // and the other two answers land on the same finish-in-app nudge
        // they would anyway (see WalletDraftCompletion).
        let description = info?.payeeName ?? merchant
        let friend = friendWithoutAsking(template: template)
        let draftId = TransactionDraftGuard.beginAwaitingSplitChoice(
            payload,
            context: TransactionDraft.PendingSplitContext(
                description: description,
                friendId: friend?.id,
                friendFirstName: friend?.firstName,
                friendFullName: friend?.fullName
            )
        )
        TransactionClaimStore.awaitConfirmation(claimId, draftId: draftId)
        return String(
            format: String(localized: "%@ at %@ – waiting on your split choice."),
            amount.asMoneyString,
            description
        )
    }

    /// The friend to split with as far as saved state can settle it: the
    /// template's cached one, else the app-wide default. Nil means the
    /// question genuinely can't be answered without asking.
    static func friendWithoutAsking(template: WalletTransactionConfig.Template?) -> SplitwiseFriendEntity? {
        if let cached = template?.splitwiseFriend {
            return SplitwiseFriendEntity(id: cached.id, firstName: cached.firstName, fullName: cached.fullName)
        }
        return SplitwiseDefaultFriendStore.load().map {
            SplitwiseFriendEntity(id: $0.id, firstName: $0.firstName, fullName: $0.fullName)
        }
    }

    /// Records category usage on success and describes a YNAB write as a
    /// dialog string — shared by the standalone YNAB intent and both
    /// wallet-to-YNAB entry points, all of which use this exact wording.
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
            return "\(formattedAmount) at \(payeeName)"
        case .queued:
            return "No connection – \(formattedAmount) at \(payeeName) – queued for sync"
        }
    }

    /// Describes a Splitwise-only wallet expense's outcome — shared by
    /// AddWalletTransactionToSplitwiseIntent and
    /// ContinueSplitwiseWalletTransactionView. Distinct from the standalone
    /// AddSplitwiseExpenseIntent, which deliberately omits the amount from
    /// its own dialog wording.
    static func splitwiseWalletDialog(
        outcome: SplitwiseExpenseOutcome,
        formattedAmount: String,
        description: String
    ) -> String {
        switch outcome {
        case .created(let shareSummary):
            "\(formattedAmount) at \(description) – \(shareSummary)"
        case .queued:
            "No connection – \(formattedAmount) at \(description) – queued for sync"
        }
    }

    static func splitwiseSkippedDialog(description: String) -> String {
        "Skipping \(description) — merchant is set to not split."
    }
}
