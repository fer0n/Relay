//
//  AddLedgerExpenseIntent.swift
//  Relay
//
//  Siri/Shortcuts equivalent of the "Splitwise Master" Shortcut this app
//  replaced (see docs/project-goals.md), now writing to a shared iCloud
//  ledger. Fields mirror that shortcut: cost, description, and an optional
//  own share (splits the cost equally when left blank). The signed-in user
//  always pays the full cost up front and is owed back the others' shares.
//
//  Replaces AddSplitwiseExpenseIntent, which was deleted rather than
//  renamed — a saved shortcut referencing it will show a missing action and
//  needs re-adding. There was no way to avoid that: Shortcuts keys on the
//  intent's type name, and keeping the old one alive would have meant an
//  action called "Add Splitwise Expense" that writes somewhere else.
//

import AppIntents

struct AddLedgerExpenseIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Shared Expense"
    static let description = IntentDescription("Adds an expense to a shared iCloud ledger.")

    @Parameter(title: "Amount", description: "The total expense amount, e.g. 12.34")
    var amount: Double

    @Parameter(title: "Description")
    var expenseDescription: String

    @Parameter(title: "Split With")
    var target: SplitTargetEntity

    @Parameter(title: "Your Share", description: "Leave blank to split the cost equally")
    var ownShare: Double?

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$amount) expense for \(\.$expenseDescription) split with \(\.$target)") {
            \.$ownShare
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await PendingOperationQueue.shared.flush()

        let outcome = try await SplitExpenseService.addExpense(
            amount: amount,
            description: expenseDescription,
            friend: target,
            ownShare: ownShare
        )
        switch outcome {
        case .created(let shareSummary):
            return .result(dialog: "\(expenseDescription) – \(shareSummary)")
        case .queued:
            return .result(dialog: "No connection – \(expenseDescription) – queued for sync")
        }
    }
}
