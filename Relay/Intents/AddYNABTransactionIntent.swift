//
//  AddYNABTransactionIntent.swift
//  Relay
//
//  Siri/Shortcuts equivalent of the "Add YNAB Expense" Shortcut being replaced
//  (see docs/project-goals.md), with the same fields.
//
//  `splitwiseOption` mirrors the original's "splitwise" field: set it fixed for
//  always/never, or leave it "Ask Each Time" for a live per-run choice.
//

import AppIntents

struct AddYNABTransactionIntent: AppIntent {
    static let title: LocalizedStringResource = "Add YNAB Transaction"
    static let description = IntentDescription("Adds an expense transaction to your YNAB plan.")

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

        // parameterSummary has to be a compile-time value, so splitwiseOption can't
        // be hidden when Splitwise isn't connected. Treat it as "never split" at
        // run time rather than prompting for a friend/share that can only fail.
        let effectiveSplitwiseOption = SplitwiseAuthService.currentAccessToken != nil ? splitwiseOption : .never

        // Resolve everything before the YNAB call below: throwing needsValueError
        // re-runs perform() from the top, which would otherwise create a second,
        // duplicate transaction. (The wallet intents instead use the async
        // `requestValue`, which suspends in place.)
        if effectiveSplitwiseOption != .never, splitwiseFriend == nil {
            throw $splitwiseFriend.needsValueError("Split with which Splitwise friend?")
        }
        if effectiveSplitwiseOption == .manual, splitwiseOwnShare == nil {
            let formattedAmount = amount.asMoneyString
            let friendName = splitwiseFriend?.firstName ?? "your friend"
            throw $splitwiseOwnShare.needsValueError("Your share of the \(formattedAmount) expense at \(payee), split with \(friendName)?")
        }
        if effectiveSplitwiseOption == .manual, let splitwiseOwnShare {
            try SplitwiseExpenseHelper.validateOwnShare(splitwiseOwnShare, amount: amount)
        }

        // Expenses are outflows in YNAB: stored as negative milliunits.
        let milliunits = -Int((amount * Const.milliunitsPerUnit).rounded())
        let transaction = YNABTransactionRequest(
            accountId: account.id,
            date: YNABService.todayDateString(),
            amount: milliunits,
            payeeName: payee,
            categoryId: category?.id,
            memo: memo,
            cleared: cleared ? Const.YNAB.cleared : Const.YNAB.uncleared,
            approved: true
        )
        let formattedAmount = amount.asMoneyString

        // Folds the YNAB write and the split into one history entry; nil when
        // nothing will be split.
        let willSplit = effectiveSplitwiseOption != .never && splitwiseFriend != nil
        let groupId = willSplit ? UUID() : nil

        // Never depends on the YNAB call's outcome, so it runs concurrently rather
        // than paying for both round-trips back to back. Catches its own errors, so
        // a Splitwise failure can't cancel the in-flight YNAB call.
        func createSplitIfNeeded() async -> String? {
            guard effectiveSplitwiseOption != .never, let friend = splitwiseFriend else { return nil }
            // Mirrors the original shortcut's description: "payee (memo)" when a memo is set.
            let description = (memo?.isEmpty == false) ? "\(payee) (\(memo!))" : payee
            // "Always" forces an equal split even with a share set; only "Manual"
            // uses the entered one.
            let ownShare = (effectiveSplitwiseOption == .manual) ? splitwiseOwnShare : nil
            return await WalletAutomationDialog.splitDialogFragment(amount: amount, description: description, friend: friend, ownShare: ownShare, groupId: groupId).fragment
        }

        async let ynabOutcome = PendingSync.createYNABTransaction(transaction, token: token, summary: "\(formattedAmount) at \(payee)", groupId: groupId)
        async let splitDialogFragment = createSplitIfNeeded()

        let outcome = try await ynabOutcome
        var dialog = WalletAutomationDialog.handleYNABOutcome(outcome, formattedAmount: formattedAmount, payeeName: payee, categoryId: category?.id)

        if let fragment = await splitDialogFragment {
            dialog += fragment
        }

        return .result(dialog: "\(dialog)")
    }
}
