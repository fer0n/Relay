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

    enum Payload: Codable {
        case ynabWallet(merchant: String, amount: Double, card: String)
        /// `ownShare` carries forward an already-resolved manual split
        /// amount (e.g. from AddWalletTransactionToYNABIntent's Splitwise
        /// half) so ContinueSplitwiseWalletTransactionView can prefill it
        /// instead of asking again. nil when the share isn't known yet.
        case splitwiseWallet(merchant: String, amount: Double, ownShare: Double? = nil)
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
        "\(amount.asMoneyString) at \(merchant)"
    }

    /// Formatted for TransactionSummaryRow — negated to match the
    /// negative-for-money-out convention the final YNAB/Splitwise rows use
    /// (wallet automations only ever add expenses).
    var formattedAmount: String {
        (-amount).asMoneyString
    }
}
