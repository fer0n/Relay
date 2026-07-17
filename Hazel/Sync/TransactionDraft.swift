//
//  TransactionDraft.swift
//  Hazel
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
        case splitwiseWallet(merchant: String, amount: Double)
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
        case .splitwiseWallet(let merchant, _): merchant
        }
    }

    var amount: Double {
        switch payload {
        case .ynabWallet(_, let amount, _): amount
        case .splitwiseWallet(_, let amount): amount
        }
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
