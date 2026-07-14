//
//  SplitwiseExpenseHelper.swift
//  Hazel
//
//  Shared expense-splitting logic used by both the standalone "Add
//  Splitwise Expense" intent and the "Split with Splitwise" option on
//  "Add YNAB Transaction" — mirrors the original setup where both the
//  "Add YNAB Expense" and standalone flows hand off to the same
//  "Splitwise Master" Shortcut.
//

import Foundation

nonisolated enum SplitwiseExpenseHelper {
    /// Creates a non-group Splitwise expense split between the signed-in
    /// user (who pays the full cost) and `friend`; a nil `ownShare` splits
    /// the cost equally. Returns a human-readable summary of each share.
    static func addExpense(
        amount: Double,
        description: String,
        friend: SplitwiseFriendEntity,
        ownShare: Double?
    ) async throws -> String {
        guard amount.isFinite, amount > 0 else {
            throw SplitwiseIntentError.validation("Amount must be a positive number.")
        }
        if let ownShare {
            guard ownShare.isFinite, (0...amount).contains(ownShare) else {
                throw SplitwiseIntentError.validation("Your share must be between 0 and the total amount.")
            }
        }

        guard let token = SplitwiseAuthService.currentAccessToken else {
            throw SplitwiseIntentError.notAuthenticated
        }

        do {
            let user = try await SplitwiseService.fetchCurrentUser(token: token)

            let costCents = Int((amount * 100).rounded())
            let ownShareCents = ownShare.map { Int(($0 * 100).rounded()) } ?? costCents / 2
            let friendShareCents = costCents - ownShareCents

            let expense = SplitwiseExpenseRequest(
                costCents: costCents,
                description: description,
                currencyCode: "EUR",
                payerUserId: user.id,
                payerOwedCents: ownShareCents,
                friendUserId: friend.id,
                friendOwedCents: friendShareCents
            )
            try await SplitwiseService.createExpense(expense, token: token)
            SplitwiseFriendUsageStore.recordUsage(friendId: friend.id)

            let ownAmount = (Double(ownShareCents) / 100).formatted(.number.precision(.fractionLength(2)))
            let friendAmount = (Double(friendShareCents) / 100).formatted(.number.precision(.fractionLength(2)))
            return "you: \(ownAmount), \(friend.name): \(friendAmount)"
        } catch {
            throw SplitwiseIntentError.from(error)
        }
    }
}
