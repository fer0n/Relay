//
//  TransactionDraft.swift
//  Relay
//
//  A wallet transaction/expense that's been started but not confirmed created.
//  Tracked by TransactionDraftGuard, and carries the raw inputs
//  ContinueWalletTransactionView needs to finish it in-app.
//

import Foundation

nonisolated struct TransactionDraft: Codable, Identifiable {
    let id: UUID
    let startedAt: Date
    let payload: Payload

    /// Set on a `.splitwiseWallet` draft once YNAB is committed and the only thing
    /// left is the split choice. Its presence is what lets the reminder offer
    /// Split Equally / Manually / Don't Split as quick replies, and gives
    /// "dismiss = leave it, YNAB already done" its meaning. A plain
    /// `.splitwiseWallet` draft, where the split *is* the transaction, has none.
    var pendingSplitContext: PendingSplitContext?

    enum Payload: Codable {
        case ynabWallet(merchant: String, amount: Double, card: String)
        /// `ownShare` carries forward an already-resolved manual split amount so
        /// the form can prefill it instead of asking again.
        case splitwiseWallet(merchant: String, amount: Double, ownShare: Double? = nil)

        var merchant: String {
            switch self {
            case .ynabWallet(let merchant, _, _): merchant
            case .splitwiseWallet(let merchant, _, _): merchant
            }
        }

        var amount: Double {
            switch self {
            case .ynabWallet(_, let amount, _): amount
            case .splitwiseWallet(_, let amount, _): amount
            }
        }
    }

    /// What a background split-completion needs beyond the payload — captured the
    /// moment perform() is about to ask the split choice, so a notification action
    /// can create the expense without re-resolving against config.
    struct PendingSplitContext: Codable {
        /// The resolved payee/template name, also used in the notification text.
        var description: String
        /// Set when a friend was resolvable without asking. When nil, Split
        /// Equally / Manually can't finish in the background and fall back to
        /// opening the draft; Don't Split still resolves it.
        var friendId: Int?
        var friendFirstName: String?
        var friendFullName: String?

        /// nil unless all three fields are present, mirroring
        /// `WalletTransactionConfig.Template.splitwiseFriend`.
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

    var merchant: String { payload.merchant }

    var amount: Double { payload.amount }

    /// `.splitwiseWallet` only — a manual split amount the creating run had already
    /// resolved.
    var ownShare: Double? {
        if case .splitwiseWallet(_, _, let ownShare) = payload {
            return ownShare
        }
        return nil
    }

    /// True when the shortcut's Merchant/Amount resolved to nothing — no network to
    /// fetch the Wallet transaction's details, say — rather than this being a real
    /// interrupted purchase for $0 at a blank payee. Also matches the placeholder
    /// draft a manual entry starts from, which wants an editable amount too.
    var receivedNoValues: Bool {
        merchant.isEmpty && amount == 0
    }

    var summary: String {
        guard !receivedNoValues else { return String(localized: "No values received") }
        return String(localized: "\(amount.asMoneyString) at \(merchant)")
    }

    var formattedAmount: String {
        amount.asMoneyString
    }
}
