//
//  AddYNABTransactionIntent.swift
//  Hazel
//
//  Siri/Shortcuts equivalent of the "Add YNAB Expense" Shortcut being
//  replaced (see docs/project-goals.md). Fields mirror that shortcut:
//  amount, memo, payee, account, category, cleared.
//
//  "Split with Splitwise" mirrors the "splitwise" field the original "Add
//  YNAB Expense" shortcut passed into "YNAB Toolkit"/"YNAB Master": fixed
//  to "always" or "never" per duplicated shortcut there, or a live
//  Ja/Manuell/Nein (yes-equal/manual-share/no) menu otherwise. Here: set
//  `splitwiseOption` fixed for the same always/never behavior, or leave it
//  "Ask Each Time" in the Shortcuts editor for the same live per-run choice.
//

import AppIntents

nonisolated struct AddYNABTransactionIntent: AppIntent {
    static let title: LocalizedStringResource = "Add YNAB Transaction"
    static let description = IntentDescription("Adds an expense transaction to your YNAB budget.")

    @Parameter(title: "Amount", description: "The expense amount, e.g. 12.34")
    var amount: Double

    @Parameter(title: "Payee")
    var payee: String

    @Parameter(title: "Account")
    var account: YNABAccountEntity

    @Parameter(title: "Category")
    var category: YNABCategoryEntity?

    @Parameter(title: "Memo")
    var memo: String?

    @Parameter(title: "Mark as Cleared", default: false)
    var cleared: Bool

    @Parameter(title: "Split with Splitwise", default: .never)
    var splitwiseOption: SplitwiseSplitOption

    @Parameter(title: "Split With")
    var splitwiseFriend: SplitwiseFriendEntity?

    @Parameter(title: "Your Share")
    var splitwiseOwnShare: Double?

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$amount) expense at \(\.$payee) to \(\.$account)") {
            \.$category
            \.$memo
            \.$cleared
            \.$splitwiseOption
            \.$splitwiseFriend
            \.$splitwiseOwnShare
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let token = YNABAuthService.currentAccessToken else {
            throw YNABIntentError.notAuthenticated
        }

        // Resolve all needed values before the YNAB API call below: throwing
        // requestValue re-runs perform() from the top, which would otherwise
        // create a second, duplicate YNAB transaction.
        if splitwiseOption != .never, splitwiseFriend == nil {
            throw $splitwiseFriend.requestValue("Split with which Splitwise friend?")
        }
        if splitwiseOption == .manual, splitwiseOwnShare == nil {
            let formattedAmount = amount.formatted(.number.precision(.fractionLength(2)))
            let friendName = splitwiseFriend?.firstName ?? "your friend"
            throw $splitwiseOwnShare.requestValue("Your share of the \(formattedAmount) expense at \(payee), split with \(friendName)?")
        }
        if splitwiseOption == .manual, let splitwiseOwnShare {
            try SplitwiseExpenseHelper.validateOwnShare(splitwiseOwnShare, amount: amount)
        }

        do {
            // Expenses are outflows in YNAB: stored as negative milliunits.
            let milliunits = -Int((amount * 1000).rounded())
            let transaction = YNABTransactionRequest(
                accountId: account.id,
                date: YNABService.todayDateString(),
                amount: milliunits,
                payeeName: payee,
                categoryId: category?.id,
                memo: memo,
                cleared: cleared ? "cleared" : "uncleared",
                approved: true
            )
            try await YNABService.createTransaction(transaction, token: token)
            if let categoryId = category?.id {
                YNABCategoryUsageStore.recordUsage(categoryId: categoryId)
            }
        } catch {
            throw YNABIntentError.from(error)
        }

        let formattedAmount = amount.formatted(.number.precision(.fractionLength(2)))
        var dialog = "Added \(formattedAmount) at \(payee)"

        if splitwiseOption != .never, let friend = splitwiseFriend {
            // Mirrors the original shortcut's description: "payee (memo)" when a memo is set.
            let description = (memo?.isEmpty == false) ? "\(payee) (\(memo!))" : payee
            // "Always" forces an equal split even if a share happens to be
            // set; only "Manual" actually uses the entered share.
            let ownShare = (splitwiseOption == .manual) ? splitwiseOwnShare : nil
            do {
                let shareSummary = try await SplitwiseExpenseHelper.addExpense(
                    amount: amount,
                    description: description,
                    friend: friend,
                    ownShare: ownShare
                )
                dialog += ", split with Splitwise — \(shareSummary)"
            } catch {
                let message = (error as? SplitwiseIntentError)?.localizedStringResource
                    ?? "Couldn't add the Splitwise expense."
                dialog += ". \(String(localized: message))"
            }
        }

        return .result(dialog: "\(dialog)")
    }
}
