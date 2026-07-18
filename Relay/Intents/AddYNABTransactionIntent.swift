//
//  AddYNABTransactionIntent.swift
//  Relay
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
        await PendingOperationQueue.shared.flush()

        guard let token = await YNABAuthService.validAccessToken() else {
            throw YNABIntentError.notAuthenticated
        }

        // AppIntents requires parameterSummary to be a static, compile-time
        // value — it can't be hidden dynamically when Splitwise isn't
        // connected, so a YNAB-only user can still set splitwiseOption in
        // the Shortcuts editor. Treat it as "never split" at run time
        // instead, rather than prompting for a friend/share that can only
        // ever fail.
        let effectiveSplitwiseOption = SplitwiseAuthService.currentAccessToken != nil ? splitwiseOption : .never

        // Resolve all needed values before the YNAB API call below: throwing
        // requestValue re-runs perform() from the top, which would otherwise
        // create a second, duplicate YNAB transaction.
        if effectiveSplitwiseOption != .never, splitwiseFriend == nil {
            throw $splitwiseFriend.requestValue("Split with which Splitwise friend?")
        }
        if effectiveSplitwiseOption == .manual, splitwiseOwnShare == nil {
            let formattedAmount = amount.asMoneyString
            let friendName = splitwiseFriend?.firstName ?? "your friend"
            throw $splitwiseOwnShare.requestValue("Your share of the \(formattedAmount) expense at \(payee), split with \(friendName)?")
        }
        if effectiveSplitwiseOption == .manual, let splitwiseOwnShare {
            try SplitwiseExpenseHelper.validateOwnShare(splitwiseOwnShare, amount: amount)
        }

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
        let formattedAmount = amount.asMoneyString

        // Never depends on the YNAB call's outcome, so it runs concurrently
        // with it instead of paying for both round-trips back to back.
        // Catches its own errors (never throws) so a Splitwise failure never
        // cancels the still-in-flight YNAB call.
        func createSplitIfNeeded() async -> String? {
            guard effectiveSplitwiseOption != .never, let friend = splitwiseFriend else { return nil }
            // Mirrors the original shortcut's description: "payee (memo)" when a memo is set.
            let description = (memo?.isEmpty == false) ? "\(payee) (\(memo!))" : payee
            // "Always" forces an equal split even if a share happens to be
            // set; only "Manual" actually uses the entered share.
            let ownShare = (effectiveSplitwiseOption == .manual) ? splitwiseOwnShare : nil
            return await WalletAutomationDialog.splitDialogFragment(amount: amount, description: description, friend: friend, ownShare: ownShare)
        }

        async let ynabOutcome = PendingSync.createYNABTransaction(transaction, token: token, summary: "\(formattedAmount) at \(payee)")
        async let splitDialogFragment = createSplitIfNeeded()

        let outcome = try await ynabOutcome
        var dialog = WalletAutomationDialog.handleYNABOutcome(outcome, formattedAmount: formattedAmount, payeeName: payee, categoryId: category?.id)

        if let fragment = await splitDialogFragment {
            dialog += fragment
        }

        return .result(dialog: "\(dialog)")
    }
}
