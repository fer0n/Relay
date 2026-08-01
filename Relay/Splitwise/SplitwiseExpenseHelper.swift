//
//  SplitwiseExpenseHelper.swift
//  Relay
//
//  Shared expense-splitting logic, used by both the standalone "Add Splitwise
//  Expense" intent and the "Split with Splitwise" option on "Add YNAB
//  Transaction" — mirroring the original Shortcut setup.
//

import Foundation

enum SplitwiseOwnShareParse {
    case valid(Double)
    case invalid(message: String)
}

enum SplitwiseExpenseOutcome {
    case created(shareSummary: String)
    /// Handed to PendingOperationQueue, to be created once connectivity returns.
    case queued
}

nonisolated enum SplitwiseExpenseHelper {
    /// Exposed so callers can validate the share *before* creating the YNAB
    /// transaction — otherwise a bad share leaves that transaction created with no
    /// matching Splitwise expense and only a dialog hint about it.
    static func validateOwnShare(_ ownShare: Double, amount: Double) throws {
        guard ownShare.isFinite, (0...amount).contains(ownShare) else {
            throw SplitwiseIntentError.validation("Your share must be between 0 and the total amount.")
        }
    }

    /// Parses and validates a form's own-share field against the total, returning
    /// either the amount or a user-facing message.
    static func parseOwnShare(_ text: String, amount: Double) -> SplitwiseOwnShareParse {
        guard let parsed = Double(text) else {
            return .invalid(message: "Enter a valid share amount.")
        }
        do {
            try validateOwnShare(parsed, amount: amount)
        } catch {
            let message = (error as? SplitwiseIntentError)
                .map { String(localized: $0.localizedStringResource) } ?? "Invalid share amount."
            return .invalid(message: message)
        }
        return .valid(parsed)
    }

    /// Creates a non-group expense between the signed-in user, who fronts the whole
    /// cost, and `friend`; a nil `ownShare` splits it equally. `groupId` folds this
    /// into the same history entry as its run's YNAB transaction.
    static func addExpense(
        amount: Double,
        description: String,
        friend: SplitwiseFriendEntity,
        ownShare: Double?,
        date: Date? = nil,
        groupId: UUID? = nil,
        merchant: String? = nil
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

        // Falls back to the cached id when offline, so a queued expense can still be
        // assembled instead of failing before it reaches the queue-for-later path.
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

        let costCents = Int((amount * Const.centsPerUnit).rounded())
        let ownShareCents = ownShare.map { Int(($0 * Const.centsPerUnit).rounded()) } ?? costCents / 2
        let friendShareCents = costCents - ownShareCents

        let expense = SplitwiseExpenseRequest(
            costCents: costCents,
            description: description,
            currencyCode: Const.currencyCode,
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
            summary: "\(formattedAmount) expense for \(description), split with \(friend.firstName)",
            groupId: groupId,
            merchant: merchant
        )

        switch outcome {
        case .created:
            SplitwiseFriendUsageStore.recordUsage(friendId: friend.id)
            // Force-refreshes the friend balance rather than leaving it to the next
            // staleness-based fetch, so a just-posted expense shows immediately.
            Task { _ = try? await SplitwiseFriendCacheStore.fetch(token: token) }
            let ownAmount = (Double(ownShareCents) / Const.centsPerUnit).asMoneyString
            let friendAmount = (Double(friendShareCents) / Const.centsPerUnit).asMoneyString
            return .created(shareSummary: "You: \(ownAmount); \(friend.firstName): \(friendAmount)")
        case .queued:
            // Queued for later, so there's nothing to refresh yet.
            return .queued
        }
    }
}
