//
//  SplitExpenseService.swift
//  Relay
//
//  The entry point for creating a split: the transaction form, the Shortcuts
//  intents and the statement-file import all come through here.
//

import Foundation

/// `.queued` is the offline path. Callers distinguish the two so nothing
/// reads as synced while it isn't.
enum SplitExpenseOutcome {
    case created(shareSummary: String)
    case queued
}

nonisolated enum OwnShareParse {
    case valid(Double)
    case invalid(message: String)
}

@MainActor
enum SplitExpenseService {
    /// The signed-in user fronts the whole cost. `groupId` groups history
    /// entries, not ledgers.
    static func addExpense(
        amount: Double,
        description: String,
        target: SplitTarget,
        allocation: SplitAllocation,
        date: Date? = nil,
        groupId: UUID? = nil,
        merchant: String? = nil
    ) async throws -> SplitExpenseOutcome {
        guard amount.isFinite, amount > 0 else {
            throw LedgerExpenseError.validation(String(localized: "Amount must be a positive number."))
        }
        guard let ledger = target.ledger else {
            throw LedgerExpenseError.validation(String(localized: "That ledger isn't available on this device any more."))
        }
        // The ledger's id first — what existing shares are keyed by. The
        // container's is the same string, for before it loads.
        guard let payerID = ledger.currentUser?.id ?? LedgerStore.shared.currentUserID else {
            throw LedgerExpenseError.notAvailable
        }

        // A whole-ledger target includes the payer, who'd be billed twice.
        let others = target.participants.filter { $0.id != payerID }
        guard !others.isEmpty else {
            throw LedgerExpenseError.validation(String(localized: "Pick at least one person to split with."))
        }

        let costCents = SplitShareMath.cents(fromAmount: amount)
        guard let shares = LedgerBalanceMath.shares(
            costCents: costCents,
            payerID: payerID,
            participantIDs: [payerID] + others.map(\.id),
            allocation: allocation
        ) else {
            throw LedgerExpenseError.validation(String(localized: "Your share must be between 0 and the total amount."))
        }

        let expense = LedgerExpense(
            title: description,
            costCents: costCents,
            currencyCode: ledger.currencyCode,
            date: date ?? Date(),
            shares: shares
        )
        let summary = "\(amount.asMoneyString) expense for \(description), split with \(target.displayName)"
        switch await LedgerStore.shared.save(
            expense,
            in: ledger,
            history: LedgerWriteHistory(summary: summary, groupId: groupId, merchant: merchant)
        ) {
        case .failed:
            throw LedgerExpenseError.writeFailed(LedgerStore.shared.lastError)
        // The queue records usage and history when the write lands.
        case .queued:
            return .queued
        case .saved:
            break
        }

        LedgerParticipantUsageStore.recordUsage(participantIDs: others.map(\.id))

        TransactionHistoryStore.record(
            summary: summary,
            payload: .ledgerExpense(LedgerExpenseRequest(expense: expense, ledger: ledger)),
            groupId: groupId,
            merchant: merchant
        )
        return .created(shareSummary: shareSummary(shares: shares, payerID: payerID, others: others))
    }

    /// The picked-entity shape. A nil `ownShare` splits equally.
    static func addExpense(
        amount: Double,
        description: String,
        friend: SplitTargetEntity,
        ownShare: Double?,
        date: Date? = nil,
        groupId: UUID? = nil,
        merchant: String? = nil
    ) async throws -> SplitExpenseOutcome {
        // Before the target resolves, and before the YNAB half exists.
        if let ownShare {
            try validateOwnShare(ownShare, amount: amount)
        }
        return try await addExpense(
            amount: amount,
            description: description,
            target: try await SplitTargetResolver.resolve(friend),
            allocation: ownShare.map { .ownShare(cents: SplitShareMath.cents(fromAmount: $0)) } ?? .equal,
            date: date,
            groupId: groupId,
            merchant: merchant
        )
    }

    private static func shareSummary(
        shares: [LedgerExpenseShare],
        payerID: String,
        others: [SplitParticipant]
    ) -> String {
        let byID = Dictionary(uniqueKeysWithValues: shares.map { ($0.participantID, $0.owedCents) })
        return ([(String(localized: "You"), byID[payerID] ?? 0)]
            + others.map { ($0.firstName, byID[$0.id] ?? 0) })
            .map { "\($0): \($1.asMoneyString)" }
            .joined(separator: "; ")
    }

    /// Checked before the YNAB transaction, which would otherwise exist with
    /// no matching split.
    nonisolated static func validateOwnShare(_ ownShare: Double, amount: Double) throws {
        guard ownShare.isFinite, (0...amount).contains(ownShare) else {
            throw LedgerExpenseError.validation(String(localized: "Your share must be between 0 and the total amount."))
        }
    }

    /// The amount, or a user-facing message. Via `SplitShareMath` so a comma
    /// decimal separator parses, as it does in every other amount field.
    nonisolated static func parseOwnShare(_ text: String, amount: Double) -> OwnShareParse {
        guard let cents = SplitShareMath.cents(text) else {
            return .invalid(message: String(localized: "Enter a valid share amount."))
        }
        let parsed = Double(cents) / Const.centsPerUnit
        do {
            try validateOwnShare(parsed, amount: amount)
        } catch {
            return .invalid(message: error.localizedDescription)
        }
        return .valid(parsed)
    }
}
