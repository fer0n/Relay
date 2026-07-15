//
//  AddSplitwiseExpenseIntent.swift
//  Hazel
//
//  Siri/Shortcuts equivalent of the "Splitwise Master" Shortcut being
//  replaced (see docs/project-goals.md). Fields mirror that shortcut: cost,
//  description, and an optional own share (splits the cost equally with
//  the chosen friend when left blank). The signed-in user always pays the
//  full cost up front and is owed back the friend's share.
//

import AppIntents

nonisolated struct AddSplitwiseExpenseIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Splitwise Expense"
    static let description = IntentDescription("Adds an expense split with a friend on Splitwise.")

    @Parameter(title: "Amount", description: "The total expense amount, e.g. 12.34")
    var amount: Double

    @Parameter(title: "Description")
    var expenseDescription: String

    @Parameter(title: "Split With")
    var friend: SplitwiseFriendEntity

    @Parameter(title: "Your Share", description: "Leave blank to split the cost equally")
    var ownShare: Double?

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$amount) expense for \(\.$expenseDescription) split with \(\.$friend)") {
            \.$ownShare
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await PendingOperationQueue.shared.flush()

        let outcome = try await SplitwiseExpenseHelper.addExpense(
            amount: amount,
            description: expenseDescription,
            friend: friend,
            ownShare: ownShare
        )
        switch outcome {
        case .created(let shareSummary):
            return .result(dialog: "Added \(expenseDescription) — \(shareSummary)")
        case .queued:
            return .result(dialog: "You're offline — queued \(expenseDescription) to add to Splitwise once you're back online")
        }
    }
}
