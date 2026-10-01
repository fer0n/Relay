//
//  TransactionDraft.swift
//  Relay
//
//  A wallet transaction/expense that's been started but not confirmed created.
//  Tracked by TransactionDraftGuard, and carries the raw inputs
//  ContinueWalletTransactionView needs to finish it in-app.
//

import Foundation

nonisolated struct TransactionDraft: Codable, Identifiable {
    let id: UUID
    let startedAt: Date
    let payload: Payload

    /// Set on a `.ledgerWallet` draft once YNAB is committed and the only thing
    /// left is the split choice. Its presence is what lets the reminder offer
    /// Split Equally / Manually / Don't Split as quick replies, and gives
    /// "dismiss = leave it, YNAB already done" its meaning. A plain
    /// `.ledgerWallet` draft, where the split *is* the transaction, has none.
    var pendingSplitContext: PendingSplitContext?

    /// The automation that saw it, on a draft left for approval by "Require
    /// Confirmation" — what makes its reminder ask Add/Discard.
    var confirmationSource: String?

    enum Payload: Codable {
        case ynabWallet(merchant: String, amount: Double, card: String)
        /// `ownShare` carries forward an already-resolved manual split amount so
        /// the form can prefill it instead of asking again.
        case ledgerWallet(merchant: String, amount: Double, ownShare: Double? = nil)

        var merchant: String {
            switch self {
            case .ynabWallet(let merchant, _, _): merchant
            case .ledgerWallet(let merchant, _, _): merchant
            }
        }

        var amount: Double {
            switch self {
            case .ynabWallet(_, let amount, _): amount
            case .ledgerWallet(_, let amount, _): amount
            }
        }
    }

    /// What a background split-completion needs beyond the payload — captured the
    /// moment perform() is about to ask the split choice, so a notification action
    /// can create the expense without re-resolving against config.
    struct PendingSplitContext: Codable {
        /// The resolved payee/template name, also used in the notification text.
        var description: String
        /// Set when a target was resolvable without asking. When nil, Split
        /// Equally / Manually can't finish in the background and fall back to
        /// opening the draft; Don't Split still resolves it.
        var ledgerZoneName: String?
        /// nil with a zone set means everyone on that ledger — the same
        /// convention `SplitTargetEntity` uses.
        var ledgerParticipantID: String?
        var targetFirstName: String?
        var targetFullName: String?

        /// nil unless the ledger and both names are present, mirroring
        /// `WalletTransactionConfig.Template.splitTarget`.
        var friend: SplitTargetEntity? {
            guard let ledgerZoneName, let targetFirstName, let targetFullName else { return nil }
            return SplitTargetEntity(
                zoneName: ledgerZoneName,
                participantID: ledgerParticipantID,
                firstName: targetFirstName,
                fullName: targetFullName
            )
        }
    }

    var service: TransactionService {
        switch payload {
        case .ynabWallet: .ynab
        case .ledgerWallet: .ledger
        }
    }

    var merchant: String { payload.merchant }

    var amount: Double { payload.amount }

    /// `.ledgerWallet` only — a manual split amount the creating run had already
    /// resolved.
    var ownShare: Double? {
        if case .ledgerWallet(_, _, let ownShare) = payload {
            return ownShare
        }
        return nil
    }

    /// True when the shortcut's Merchant/Amount resolved to nothing — no network to
    /// fetch the Wallet transaction's details, say — rather than this being a real
    /// interrupted purchase for $0 at a blank payee. Also matches the placeholder
    /// draft a manual entry starts from, which wants an editable amount too.
    var receivedNoValues: Bool {
        merchant.isEmpty && amount == 0
    }

    var summary: String {
        guard !receivedNoValues else { return String(localized: "No values received") }
        return String(localized: "\(amount.asMoneyString) at \(merchant)")
    }

    var formattedAmount: String {
        amount.asMoneyString
    }
}

nonisolated extension TransactionDraft.PendingSplitContext {
    /// Flattens a resolved "Split With" pick into the stored fields.
    init(description: String, target: SplitTargetEntity?) {
        self.init(
            description: description,
            ledgerZoneName: target?.zoneName,
            ledgerParticipantID: target?.participantID,
            targetFirstName: target?.firstName,
            targetFullName: target?.fullName
        )
    }
}
