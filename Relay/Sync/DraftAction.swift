//
//  DraftAction.swift
//  Relay
//
//  The answers a draft's reminder offers, shared by the notification categories
//  and the in-app draft screen so both always show and do the same thing.
//  Identifiers are persisted by the system with each registered category, so
//  they stay frozen.
//

import UserNotifications

nonisolated enum DraftAction: CaseIterable {
    case add
    case addSplitEqually
    case addSplitManually
    case addWithoutSplit
    case splitEqually
    case splitManually
    case dontSplit
    case discard

    init?(identifier: String) {
        guard let action = Self.allCases.first(where: { $0.identifier == identifier }) else { return nil }
        self = action
    }

    var identifier: String {
        switch self {
        case .add: "WALLET_CONFIRM_ADD"
        case .addSplitEqually: "WALLET_CONFIRM_ADD_SPLIT_EQUALLY"
        case .addSplitManually: "WALLET_CONFIRM_ADD_SPLIT_MANUAL"
        case .addWithoutSplit: "WALLET_CONFIRM_ADD_NO_SPLIT"
        case .splitEqually: "WALLET_SPLIT_EQUALLY"
        case .splitManually: "WALLET_SPLIT_MANUAL"
        case .dontSplit: "WALLET_SPLIT_NONE"
        case .discard: "WALLET_CONFIRM_DISCARD"
        }
    }

    var title: String {
        switch self {
        case .add: String(localized: "Add")
        case .addSplitEqually: String(localized: "Add & Split Equally")
        case .addSplitManually: String(localized: "Add & Split Manually…")
        case .addWithoutSplit: String(localized: "Add Without Splitting")
        case .splitEqually: String(localized: "Split Equally")
        case .splitManually: String(localized: "Split Manually…")
        case .dontSplit: String(localized: "Don't Split")
        case .discard: String(localized: "Discard")
        }
    }

    /// The manual splits take the user's own share as a typed reply.
    var asksOwnShare: Bool {
        self == .addSplitManually || self == .splitManually
    }

    var ownShareSubmitTitle: String {
        self == .splitManually ? String(localized: "Split") : String(localized: "Add")
    }

    static let ownSharePlaceholder = String(localized: "Your share, e.g. 12.50")

    /// No `.foreground`: every action finishes in the background and only
    /// re-nudges via `notifyNeedsApp` when something still has to be chosen.
    /// Discard skips `.authenticationRequired` so it can be answered from the
    /// lock screen — nothing written is at stake.
    var notificationAction: UNNotificationAction {
        if asksOwnShare {
            return UNTextInputNotificationAction(
                identifier: identifier,
                title: title,
                options: [],
                textInputButtonTitle: ownShareSubmitTitle,
                textInputPlaceholder: Self.ownSharePlaceholder
            )
        }
        return UNNotificationAction(identifier: identifier, title: title, options: self == .discard ? [.destructive] : [])
    }
}

nonisolated enum DraftNotificationCategory: CaseIterable {
    /// A purchase a "Require Confirmation" automation saw but didn't add.
    case confirm
    /// `confirm` for a YNAB purchase whose split would otherwise be a second question.
    case confirmSplit
    /// The split half of a draft whose YNAB half is done (see `PendingSplitContext`).
    case splitChoice
    /// An interrupted run — whatever it was protecting is still unwritten.
    case incomplete

    var identifier: String {
        switch self {
        case .confirm: "WALLET_CONFIRM_TRANSACTION"
        case .confirmSplit: "WALLET_CONFIRM_SPLIT"
        case .splitChoice: "WALLET_SPLIT_CHOICE"
        case .incomplete: "WALLET_TRANSACTION_INCOMPLETE"
        }
    }

    var actions: [DraftAction] {
        switch self {
        case .confirm: [.add, .discard]
        case .confirmSplit: [.addSplitEqually, .addSplitManually, .addWithoutSplit, .discard]
        case .splitChoice: [.splitEqually, .splitManually, .dontSplit]
        case .incomplete: [.discard]
        }
    }

    var category: UNNotificationCategory {
        UNNotificationCategory(
            identifier: identifier,
            actions: actions.map(\.notificationAction),
            intentIdentifiers: [],
            options: []
        )
    }
}

nonisolated extension TransactionDraft {
    var notificationCategory: DraftNotificationCategory {
        if pendingSplitContext != nil { return .splitChoice }
        guard confirmationSource != nil else { return .incomplete }
        return WalletAutomationDialog.confirmationOffersSplit(payload) ? .confirmSplit : .confirm
    }
}

nonisolated enum DraftActionHandler {
    enum Outcome {
        /// `title`/`dialog` are ready to show as-is.
        case completed(title: String, dialog: String)
        /// Finished with nothing to report — discarded, or "Don't Split".
        case resolved
        /// The transaction landed but the split is still open, now as this draft.
        case followUpPosted
        /// Nothing written; the draft is intact and has to be finished in the form.
        case needsApp
    }

    static func perform(_ action: DraftAction, on draft: TransactionDraft, ownShareReply: String?) async -> Outcome {
        switch action {
        case .discard:
            // The claim behind it is left alone: it doesn't shadow an automation
            // that can write, so this doesn't block adding the purchase later.
            TransactionDraftGuard.complete(draft.id)
            return .resolved
        case .add: return await confirm(draft, split: nil, ownShareReply: nil)
        case .addSplitEqually: return await confirm(draft, split: .always, ownShareReply: nil)
        case .addSplitManually: return await confirm(draft, split: .manual, ownShareReply: ownShareReply)
        case .addWithoutSplit: return await confirm(draft, split: .never, ownShareReply: nil)
        case .splitEqually: return await completeSplit(draft, action: .always, ownShareReply: nil)
        case .splitManually: return await completeSplit(draft, action: .manual, ownShareReply: ownShareReply)
        case .dontSplit: return await completeSplit(draft, action: .never, ownShareReply: nil)
        }
    }

    private static func confirm(_ draft: TransactionDraft, split: SplitOption?, ownShareReply: String?) async -> Outcome {
        switch await WalletDraftConfirmation.confirm(draft, split: split, ownShareReply: ownShareReply) {
        case .completed(let title, let dialog): .completed(title: title, dialog: dialog)
        case .followUpPosted: .followUpPosted
        case .needsApp: .needsApp
        }
    }

    private static func completeSplit(_ draft: TransactionDraft, action: SplitOption, ownShareReply: String?) async -> Outcome {
        switch await WalletDraftCompletion.complete(draft: draft, action: action, ownShareReply: ownShareReply) {
        case .completed(let title, let dialog): .completed(title: title, dialog: dialog)
        case .resolved: .resolved
        case .needsApp: .needsApp
        }
    }
}
