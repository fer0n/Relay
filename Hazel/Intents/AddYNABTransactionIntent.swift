//
//  AddYNABTransactionIntent.swift
//  Hazel
//
//  Siri/Shortcuts equivalent of the "Add YNAB Expense" Shortcut being
//  replaced (see docs/project-goals.md). Fields mirror that shortcut:
//  amount, memo, payee, account, category, cleared.
//

import AppIntents

nonisolated struct AddYNABTransactionIntent: AppIntent {
    static let title: LocalizedStringResource = "Add YNAB Transaction"
    static let description = IntentDescription("Adds an expense transaction to your YNAB budget.")

    @Parameter(title: "Budget")
    var budget: YNABBudgetEntity

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

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$amount) expense at \(\.$payee) to \(\.$account)") {
            \.$budget
            \.$category
            \.$memo
            \.$cleared
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let token = YNABAuthService.currentAccessToken else {
            throw YNABIntentError.notAuthenticated
        }

        do {
            let budgetID = budget.id
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
            try await YNABService.createTransaction(transaction, budgetID: budgetID, token: token)
        } catch {
            throw YNABIntentError.from(error)
        }

        let formattedAmount = amount.formatted(.number.precision(.fractionLength(2)))
        return .result(dialog: "Added \(formattedAmount) at \(payee)")
    }
}
