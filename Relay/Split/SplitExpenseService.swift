//
//  SplitExpenseService.swift
//  Relay
//
//  The entry point for creating a split. Every caller — the transaction form,
//  the Shortcuts intents, the statement-file import — comes through here.
//

import Foundation

/// `.queued` is the offline path: the expense is on the ledger locally and
/// `PendingOperationQueue` retries the CloudKit write. The callers' dialogs
/// distinguish the two so nothing reads as synced while it isn't.
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
    /// An expense the signed-in user fronts the whole cost of, split across
    /// `target`. `groupId` groups history entries, not ledgers.
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
        // The ledger's own id first — what every existing share is keyed
        // by. The container's is the same string, for before it loads.
        guard let payerID = ledger.currentUser?.id ?? LedgerStore.shared.currentUserID else {
            throw LedgerExpenseError.notAvailable
        }

        // A whole-ledger target includes the payer, who'd be billed twice.
        let others = target.participants.filter { $0.id != payerID }
        guard !others.isEmpty else {
            throw LedgerExpenseError.validation(String(localized: "Pick at least one person to split with."))
        }

        let costCents = Int((amount * Const.centsPerUnit).rounded())
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
        // The usage ranking and the history entry are recorded by the queue
        // when the write lands, the same way the YNAB half of an offline run
        // defers both.
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

    /// The picked-entity shape, for the Shortcuts intents, the wallet
    /// automation and the file import. A nil `ownShare` splits equally.
    static func addExpense(
        amount: Double,
        description: String,
        friend: SplitTargetEntity,
        ownShare: Double?,
        date: Date? = nil,
        groupId: UUID? = nil,
        merchant: String? = nil
    ) async throws -> SplitExpenseOutcome {
        // Before the target resolves, so a bad share fails without a round
        // trip — and before the YNAB half exists, at the sites that do both.
        if let ownShare {
            try validateOwnShare(ownShare, amount: amount)
        }
        return try await addExpense(
            amount: amount,
            description: description,
            target: try await SplitTargetResolver.resolve(friend),
            allocation: ownShare.map { .ownShare(cents: Int(($0 * Const.centsPerUnit).rounded())) } ?? .equal,
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
            .map { "\($0): \((Double($1) / Const.centsPerUnit).asMoneyString)" }
            .joined(separator: "; ")
    }

    /// So callers can check before creating the YNAB transaction, which would
    /// otherwise exist with no matching split.
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
