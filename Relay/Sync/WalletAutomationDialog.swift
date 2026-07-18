//
//  WalletAutomationDialog.swift
//  Relay
//
//  Shared "what actually happened, in words" logic for the wallet
//  automations — used identically by the Shortcuts intents
//  (AddYNABTransactionIntent, AddWalletTransactionToYNABIntent,
//  AddWalletTransactionToSplitwiseIntent) and their in-app resume
//  counterparts (ContinueYNABWalletTransactionView,
//  ContinueSplitwiseWalletTransactionView). The two entry points ask their
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
        ownShare: Double?
    ) async -> String {
        do {
            let outcome = try await SplitwiseExpenseHelper.addExpense(
                amount: amount,
                description: description,
                friend: friend,
                ownShare: ownShare
            )
            switch outcome {
            case .created(let shareSummary):
                return " – \(shareSummary)"
            case .queued:
                return " – split queued for sync"
            }
        } catch {
            let message = (error as? SplitwiseIntentError)?.localizedStringResource
                ?? "Couldn't add the Splitwise expense."
            return " – \(String(localized: message))"
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
