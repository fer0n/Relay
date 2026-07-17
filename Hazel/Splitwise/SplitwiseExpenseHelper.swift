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

enum SplitwiseExpenseOutcome {
    case created(shareSummary: String)
    /// Offline — the expense was handed to PendingOperationQueue and will
    /// be created automatically once connectivity returns.
    case queued
}

nonisolated enum SplitwiseExpenseHelper {
    /// Shared so callers (AddYNABTransactionIntent, AddWalletTransactionToYNABIntent)
    /// can validate the share *before* creating a YNAB transaction, rather
    /// than finding out only when addExpense is called afterwards — which
    /// would leave the YNAB transaction created with no matching Splitwise
    /// expense and just a dialog hint about it.
    static func validateOwnShare(_ ownShare: Double, amount: Double) throws {
        guard ownShare.isFinite, (0...amount).contains(ownShare) else {
            throw SplitwiseIntentError.validation("Your share must be between 0 and the total amount.")
        }
    }

    /// Creates a non-group Splitwise expense split between the signed-in
    /// user (who pays the full cost) and `friend`; a nil `ownShare` splits
    /// the cost equally. Returns a human-readable summary of each share.
    static func addExpense(
        amount: Double,
        description: String,
        friend: SplitwiseFriendEntity,
        ownShare: Double?,
        date: Date? = nil
    ) async throws -> SplitwiseExpenseOutcome {
        guard amount.isFinite, amount > 0 else {
            throw SplitwiseIntentError.validation("Amount must be a positive number.")
        }
        if let ownShare {
            try validateOwnShare(ownShare, amount: amount)
        }

        guard let token = SplitwiseAuthService.currentAccessToken else {
            throw SplitwiseIntentError.notAuthenticated
        }

        // Needs the signed-in user's id to build the expense request below.
        // Falls back to the last cached value when offline, so a queued
        // expense can still be assembled instead of failing before it ever
        // reaches PendingSync's queue-for-later path.
        let user: SplitwiseUser
        do {
            user = try await PendingSync.retryOnConnectivityFailure {
                try await SplitwiseService.fetchCurrentUser(token: token)
            }
            try? SplitwiseCurrentUserStore.save(user)
        } catch {
            if error.isConnectivityFailure, let cached = SplitwiseCurrentUserStore.load() {
                user = cached
            } else {
                throw SplitwiseIntentError.from(error)
            }
        }

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
            friendOwedCents: friendShareCents,
            date: date.map { DateFormatter.yyyyMMdd.string(from: $0) }
        )

        let formattedAmount = amount.asMoneyString
        let outcome = try await PendingSync.createSplitwiseExpense(
            expense,
            token: token,
            summary: "\(formattedAmount) expense for \(description), split with \(friend.firstName)"
        )

        switch outcome {
        case .created:
            SplitwiseFriendUsageStore.recordUsage(friendId: friend.id)
            let ownAmount = (Double(ownShareCents) / 100).asMoneyString
            let friendAmount = (Double(friendShareCents) / 100).asMoneyString
            return .created(shareSummary: "you: \(ownAmount), \(friend.firstName): \(friendAmount)")
        case .queued:
            return .queued
        }
    }
}
