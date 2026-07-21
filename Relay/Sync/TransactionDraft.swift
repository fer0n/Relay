//
//  TransactionDraft.swift
//  Relay
//
//  A wallet transaction/expense that's been started (Merchant/Amount seen)
//  but not yet confirmed created — tracked by TransactionDraftGuard so the
//  wallet automations' "Ensure Completion" parameter can nudge the user
//  with a notification if the run gets interrupted before finishing, and so
//  ContinueYNABWalletTransactionView/ContinueSplitwiseWalletTransactionView
//  have the raw inputs needed to actually finish it in-app.
//

import Foundation

struct TransactionDraft: Codable, Identifiable {
    let id: UUID
    let startedAt: Date
    let payload: Payload

    /// Set on a `.splitwiseWallet` draft once the YNAB transaction has
    /// already been committed and the *only* thing left is the optional
    /// "split with Splitwise?" choice. Its presence is what lets the reminder
    /// offer Split Equally / Manually / Don't Split answerable straight from
    /// the notification (see WalletDraftCompletion) and gives "dismiss =
    /// leave it, YNAB already done" its meaning — a plain `.splitwiseWallet`
    /// draft (e.g. from AddWalletTransactionToSplitwiseIntent, where the
    /// split *is* the transaction) has none and stays an ordinary
    /// tap-to-finish reminder. nil for old drafts, which decode as nil.
    var pendingSplitContext: PendingSplitContext?

    enum Payload: Codable {
        case ynabWallet(merchant: String, amount: Double, card: String)
        /// `ownShare` carries forward an already-resolved manual split
        /// amount (e.g. from AddWalletTransactionToYNABIntent's Splitwise
        /// half) so ContinueSplitwiseWalletTransactionView can prefill it
        /// instead of asking again. nil when the share isn't known yet.
        case splitwiseWallet(merchant: String, amount: Double, ownShare: Double? = nil)
    }

    /// Everything a background split-completion needs beyond the payload's
    /// merchant/amount: the resolved expense description and the friend to
    /// split with — captured the moment perform() is about to ask the split
    /// choice, so a notification action can create the Splitwise expense
    /// without re-resolving against config.
    struct PendingSplitContext: Codable {
        /// The Splitwise expense description (the resolved payee/template
        /// name) — also used for the "Split with …" notification.
        var description: String
        /// The friend to split with, if one was already resolvable without
        /// asking (explicit override, template friend, or the app-wide
        /// default). When nil, Split Equally / Manually can't finish in the
        /// background — they need a friend picked in-app — so those fall back
        /// to opening the draft; Don't Split still resolves it.
        var friendId: Int?
        var friendFirstName: String?
        var friendFullName: String?

        /// nil unless all three friend fields are present — mirrors
        /// WalletTransactionConfig.Template.splitwiseFriend's all-or-nothing
        /// treatment.
        var friend: SplitwiseFriendEntity? {
            guard let friendId, let friendFirstName, let friendFullName else { return nil }
            return SplitwiseFriendEntity(id: friendId, firstName: friendFirstName, fullName: friendFullName)
        }
    }

    var service: TransactionService {
        switch payload {
        case .ynabWallet: .ynab
        case .splitwiseWallet: .splitwise
        }
    }

    var merchant: String {
        switch payload {
        case .ynabWallet(let merchant, _, _): merchant
        case .splitwiseWallet(let merchant, _, _): merchant
        }
    }

    var amount: Double {
        switch payload {
        case .ynabWallet(_, let amount, _): amount
        case .splitwiseWallet(_, let amount, _): amount
        }
    }

    /// Only ever set on `.splitwiseWallet` — an already-known manual split
    /// amount carried forward from the run that created this draft.
    var ownShare: Double? {
        if case .splitwiseWallet(_, _, let ownShare) = payload {
            return ownShare
        }
        return nil
    }

    var summary: String {
        String(localized: "\(amount.asMoneyString) at \(merchant)")
    }

    var formattedAmount: String {
        amount.asMoneyString
    }
}
