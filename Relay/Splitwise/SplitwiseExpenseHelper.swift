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

    /// The entity shape, used by the callers that split with one picked target
    /// (the Shortcuts intents, the statement-file import): a nil `ownShare`
    /// splits equally, otherwise everyone else shares the remainder.
    static func addExpense(
        amount: Double,
        description: String,
        friend: SplitwiseSplitTargetEntity,
        ownShare: Double?,
        date: Date? = nil,
        groupId: UUID? = nil,
        merchant: String? = nil
    ) async throws -> SplitwiseExpenseOutcome {
        if let ownShare {
            try validateOwnShare(ownShare, amount: amount)
        }
        return try await addExpense(
            amount: amount,
            description: description,
            target: try await splitTarget(for: friend),
            allocation: ownShare.map { .ownShare(cents: Int(($0 * Const.centsPerUnit).rounded())) } ?? .equal,
            date: date,
            groupId: groupId,
            merchant: merchant
        )
    }

    /// Resolves a picked entity into the people it bills. A friend is itself; a
    /// group is its membership, which has to be looked up — the entity only
    /// carries the group's name.
    static func splitTarget(for entity: SplitwiseSplitTargetEntity) async throws -> SplitwiseSplitTarget {
        guard entity.kind == .group else {
            return SplitwiseSplitTarget(friend: entity)
        }
        let groupId = entity.splitwiseId
        var groups = SplitwiseGroupCacheStore.load() ?? []
        if !groups.contains(where: { $0.id == groupId }), let token = SplitwiseAuthService.currentAccessToken {
            // Cache miss rather than a routine refresh — a group picked in a
            // shortcut months ago may never have been cached on this device.
            groups = (try? await SplitwiseGroupCacheStore.fetch(token: token)) ?? groups
        }
        guard let group = groups.first(where: { $0.id == groupId }) else {
            throw SplitwiseIntentError.validation("Couldn't find that Splitwise group.")
        }
        let members = group.others(excluding: SplitwiseCurrentUserStore.load()?.id)
            .map(SplitwiseSplitParticipant.init(member:))
        return SplitwiseSplitTarget(participants: members, groupId: group.id, groupName: group.name)
    }

    /// Creates an expense the signed-in user fronts the whole cost of, split
    /// across `target` — a set of friends as a personal expense, or a group,
    /// in which case it's posted under that group's id. `groupId` is Relay's
    /// own history grouping id (unrelated to Splitwise groups): it folds this
    /// into the same history entry as its run's YNAB transaction.
    static func addExpense(
        amount: Double,
        description: String,
        target: SplitwiseSplitTarget,
        allocation: SplitwiseSplitAllocation,
        date: Date? = nil,
        groupId: UUID? = nil,
        merchant: String? = nil
    ) async throws -> SplitwiseExpenseOutcome {
        guard amount.isFinite, amount > 0 else {
            throw SplitwiseIntentError.validation("Amount must be a positive number.")
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

        // The signed-in user can be in the group they picked, and would
        // otherwise be billed twice — once as payer, once as a member.
        let others = target.participants.filter { $0.id != user.id }
        guard !others.isEmpty else {
            throw SplitwiseIntentError.validation("Pick at least one person to split with.")
        }

        let costCents = Int((amount * Const.centsPerUnit).rounded())
        guard let owed = allocation.owedCents(totalCents: costCents, participantCount: others.count) else {
            throw SplitwiseIntentError.validation("Your share must be between 0 and the total amount.")
        }

        let participants = [SplitwiseExpenseRequest.Participant(userId: user.id, paidCents: costCents, owedCents: owed[0])]
            + zip(others, owed.dropFirst()).map { SplitwiseExpenseRequest.Participant(userId: $0.id, paidCents: 0, owedCents: $1) }

        let expense = SplitwiseExpenseRequest(
            costCents: costCents,
            description: description,
            currencyCode: Const.currencyCode,
            groupId: target.groupId ?? 0,
            participants: participants,
            date: date.map { DateFormatter.yyyyMMdd.string(from: $0) }
        )

        let formattedAmount = amount.asMoneyString
        let outcome = try await PendingSync.createSplitwiseExpense(
            expense,
            token: token,
            summary: "\(formattedAmount) expense for \(description), split with \(target.displayName)",
            groupId: groupId,
            merchant: merchant
        )

        switch outcome {
        case .created:
            for participant in others {
                SplitwiseFriendUsageStore.recordUsage(friendId: participant.id)
            }
            // Force-refreshes the friend balance rather than leaving it to the next
            // staleness-based fetch, so a just-posted expense shows immediately.
            Task { _ = try? await SplitwiseFriendCacheStore.fetch(token: token) }
            let shares = [(String(localized: "You"), owed[0])]
                + zip(others, owed.dropFirst()).map { ($0.firstName, $1) }
            let shareSummary = shares
                .map { "\($0): \((Double($1) / Const.centsPerUnit).asMoneyString)" }
                .joined(separator: "; ")
            return .created(shareSummary: shareSummary)
        case .queued:
            // Queued for later, so there's nothing to refresh yet.
            return .queued
        }
    }
}
