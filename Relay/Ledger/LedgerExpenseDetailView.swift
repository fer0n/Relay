//
//  LedgerExpenseDetailView.swift
//  Relay
//
//  One expense on a ledger — the one detail screen that edits and saves back.
//
//  A ledger stores only the final per-person amounts, not how they were
//  arrived at, so the split mode is inferred on open and every amount is
//  re-derived from the total rather than typed per person. That's what keeps
//  the numbers adding up, and CloudKit checks nothing.
//

import SwiftUI

struct LedgerExpenseDetailView: View {
    let expense: LedgerExpense
    let ledger: Ledger
    let onSave: (LedgerExpense) async throws -> Void
    let onDelete: () async -> Void

    private enum SplitMode: Hashable {
        case equally
        /// Two participants only, where "the other one" is unambiguous.
        case fullAmount
        case shares
        /// Typed in directly, so they have to add up on their own. What a
        /// reopened custom split comes back as.
        case manual

        var label: String {
            switch self {
            case .equally: return String(localized: "Equally")
            case .fullAmount: return String(localized: "Full amount")
            case .shares: return String(localized: "Shares")
            case .manual: return String(localized: "Manual")
            }
        }
    }

    private struct Participant {
        let id: String
        let name: String
    }

    @State private var totalText: String
    @State private var descriptionText: String
    @State private var payer: Int
    @State private var splitMode: SplitMode
    /// `.shares` only, positionally matching `participants`.
    @State private var weights: [String]
    /// `.manual` only, positionally matching `participants`.
    @State private var manualAmounts: [String]
    @State private var isSaving = false
    @State private var saveError: String?

    private let participants: [Participant]
    private let originalTotalCents: Int
    private let originalOwedCents: [Int]
    private let originalPaidCents: [Int]

    @Environment(\.dismiss) private var dismiss

    init(
        expense: LedgerExpense,
        ledger: Ledger,
        onSave: @escaping (LedgerExpense) async throws -> Void,
        onDelete: @escaping () async -> Void
    ) {
        self.expense = expense
        self.ledger = ledger
        self.onSave = onSave
        self.onDelete = onDelete

        // Everyone billable, since a save overwrites every share at once —
        // plus anyone on the expense who no longer is, whose share would
        // otherwise be redistributed the moment this screen opens.
        let billable = [ledger.currentUser].compactMap { $0 } + ledger.others
        let billableIDs = Set(billable.map(\.id))
        let historical = expense.shares
            .map(\.participantID)
            .filter { !billableIDs.contains($0) }
            .map { Participant(id: $0, name: ledger.participant(id: $0)?.displayName ?? LedgerParticipant.unknownName) }
        let people = billable.map { Participant(id: $0.id, name: $0.displayName) } + historical
        let owed = people.map { expense.share(for: $0.id)?.owedCents ?? 0 }
        let paid = people.map { expense.share(for: $0.id)?.paidCents ?? 0 }
        // Whoever fronted the most; a multi-payer expense collapses, which
        // the Save bar surfaces as a change.
        let payerIndex = paid.indices.max(by: { paid[$0] < paid[$1] }) ?? 0

        participants = people
        originalTotalCents = expense.costCents
        originalOwedCents = owed
        originalPaidCents = paid

        _totalText = State(initialValue: SplitShareMath.text(fromCents: expense.costCents))
        _descriptionText = State(initialValue: expense.title)
        _payer = State(initialValue: payerIndex)
        _splitMode = State(initialValue: Self.inferMode(totalCents: expense.costCents, owedCents: owed, payer: payerIndex))
        _weights = State(initialValue: Array(repeating: "1", count: people.count))
        _manualAmounts = State(initialValue: owed.map { SplitShareMath.text(fromCents: $0) })
    }

    /// Anything but an even division or a two-person "one owes everything"
    /// comes back as `.manual`.
    private static func inferMode(totalCents: Int, owedCents: [Int], payer: Int) -> SplitMode {
        guard totalCents > 0 else { return .equally }
        let count = owedCents.count
        if owedCents == SplitShareMath.distribute(totalCents: totalCents, ratios: SplitShareMath.evenRatios(count: count)) {
            return .equally
        }
        if count == 2, owedCents == (0..<2).map({ $0 == payer ? 0 : totalCents }) {
            return .fullAmount
        }
        return .manual
    }

    // MARK: - Derived state

    private var totalCents: Int? { SplitShareMath.cents(totalText) }

    private var trimmedDescription: String {
        descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Always adds up to the total, which `isBalanced` re-checks on write.
    private func owedCents(total: Int) -> [Int] {
        switch splitMode {
        case .equally:
            return SplitShareMath.distribute(
                totalCents: total,
                ratios: SplitShareMath.evenRatios(count: participants.count)
            )
        case .fullAmount:
            return participants.indices.map { $0 == payer ? 0 : total }
        case .shares:
            let values = weights.map { Double(SplitShareMath.cents($0) ?? 0) }
            return SplitShareMath.distribute(totalCents: total, ratios: SplitShareMath.ratios(of: values))
        case .manual:
            // The one mode whose amounts aren't guaranteed to add up;
            // `validationMessage` enforces it instead.
            return manualAmounts.map { SplitShareMath.cents($0) ?? 0 }
        }
    }

    private func paidCents(total: Int) -> [Int] {
        participants.indices.map { $0 == payer ? total : 0 }
    }

    /// Parseable, not adding up — that's `validationMessage`'s concern.
    private var splitInputsValid: Bool {
        switch splitMode {
        case .equally, .fullAmount:
            return true
        case .shares:
            let parsed = weights.map { SplitShareMath.cents($0) }
            guard !parsed.contains(where: { $0 == nil }) else { return false }
            return parsed.compactMap { $0 }.reduce(0, +) > 0
        case .manual:
            return !manualAmounts.contains { SplitShareMath.cents($0) == nil }
        }
    }

    /// An unparseable field counts as a change, so the bar shows disabled with
    /// the reason below it rather than leaving a broken value looking fine.
    private var hasChanges: Bool {
        if trimmedDescription != expense.title { return true }
        guard let totalCents else { return true }
        if totalCents != originalTotalCents { return true }
        if paidCents(total: totalCents) != originalPaidCents { return true }
        guard splitInputsValid else { return true }
        return owedCents(total: totalCents) != originalOwedCents
    }

    private var validationMessage: String? {
        guard !trimmedDescription.isEmpty else {
            return String(localized: "Enter a description.")
        }
        guard let totalCents, totalCents > 0 else {
            return String(localized: "Enter a valid total.")
        }
        if splitMode == .shares {
            let parsed = weights.map { SplitShareMath.cents($0) }
            guard !parsed.contains(where: { $0 == nil }) else {
                return String(localized: "Enter a valid share for everyone.")
            }
            guard parsed.compactMap({ $0 }).reduce(0, +) > 0 else {
                return String(localized: "Give at least one person a share.")
            }
        }
        if splitMode == .manual {
            let parsed = manualAmounts.map { SplitShareMath.cents($0) }
            guard !parsed.contains(where: { $0 == nil }) else {
                return String(localized: "Enter a valid amount for everyone.")
            }
            let sum = parsed.compactMap { $0 }.reduce(0, +)
            guard sum == totalCents else {
                let sumText = SplitShareMath.text(fromCents: sum)
                let expectedText = SplitShareMath.text(fromCents: totalCents)
                return String(localized: "The amounts add up to \(sumText), but the total is \(expectedText).")
            }
        }
        return nil
    }

    /// Nil when another field is unparseable or still mid-typing.
    private func manualRemaining(forIndex index: Int, total: Int) -> Int? {
        var others = 0
        for (position, text) in manualAmounts.enumerated() where position != index {
            guard let value = SplitShareMath.cents(text) else { return nil }
            others += value
        }
        return total - others
    }

    /// The picked payer, not the one that arrived.
    private var payerDetailLine: (icon: String, text: String)? {
        guard participants.indices.contains(payer) else { return nil }
        return (Const.Symbol.account, participants[payer].name)
    }

    // MARK: - Body

    var body: some View {
        let owedNow = totalCents.map { owedCents(total: $0) }

        TransactionDetailContent(
            amount: totalText,
            editableAmount: $totalText,
            serviceIcons: [TransactionService.ledger.systemImage],
            date: expense.date,
            detailLine: payerDetailLine,
            destroyLabel: "Delete",
            destroyConfirmationTitle: "Delete this expense?",
            destroyConfirmationMessage: "This will delete the expense on the ledger for everyone on it.",
            onDestroy: delete
        ) {
            Section {
                DraftDetailRow(icon: Const.Symbol.titleField, title: "Description") {
                    TextField("Description", text: $descriptionText)
                        // As the field it was typed into when added.
                        .textInputAutocapitalization(.words)
                        .multilineTextAlignment(.trailing)
                        .submitLabel(.done)
                        .autocorrectionDisabled()
                }
                .cardRowBackground()
            }

            Section {
                DraftDetailRow(icon: Const.Symbol.account, title: "Paid by") {
                    Menu {
                        ForEach(participants.indices, id: \.self) { index in
                            Button(participants[index].name) { payer = index }
                        }
                    } label: {
                        MenuPickerLabel { Text(participants.indices.contains(payer) ? participants[payer].name : "") }
                    }
                }
                .cardRowBackground()

                DraftDetailRow(icon: Const.Symbol.friends, title: "Split") {
                    Menu {
                        Button(SplitMode.equally.label) { setMode(.equally) }
                        if participants.count == 2 {
                            Button(SplitMode.fullAmount.label) { setMode(.fullAmount) }
                        }
                        Button(SplitMode.shares.label) { setMode(.shares) }
                        Button(SplitMode.manual.label) { setMode(.manual) }
                    } label: {
                        MenuPickerLabel { Text(splitMode.label) }
                    }
                }
                .cardRowBackground()

                ForEach(participants.indices, id: \.self) { index in
                    let amount = owedNow.map { SplitShareMath.text(fromCents: $0[index]) }
                    switch splitMode {
                    case .shares:
                        ShareWeightRow(
                            name: participants[index].name,
                            amountText: amount,
                            weight: $weights[index]
                        )
                    case .manual:
                        LedgerManualAmountRow(
                            name: participants[index].name,
                            amount: $manualAmounts[index],
                            remaining: totalCents.flatMap { manualRemaining(forIndex: index, total: $0) }
                        )
                    case .equally, .fullAmount:
                        DraftDetailRow(
                            icon: Const.Symbol.person,
                            title: "\(participants[index].name)",
                            isEditable: false
                        ) {
                            Text(amount ?? "—").monospacedDigit()
                        }
                        .cardRowBackground()
                    }
                }

                LedgerAmountFieldRow(icon: "sum", title: "Total", text: $totalText)
            }

            if hasChanges, let validationMessage {
                Section {
                    Text(validationMessage)
                        .foregroundStyle(.red)
                }
                .listRowBackground(Color.sheetBackgroundColor)
            }
        }
        .bottomBarActionButton(
            isPresented: hasChanges,
            title: "Save",
            isLoading: isSaving,
            isDisabled: validationMessage != nil || isSaving
        ) {
            Task { await save() }
        }
        .alert("Couldn't Save", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveError ?? "")
        }
    }

    // MARK: - Editing

    /// Seeds whatever fields the new mode owns. A custom split that *arrived*
    /// as `.manual` is seeded in `init` instead.
    private func setMode(_ mode: SplitMode) {
        switch mode {
        case .shares:
            weights = Array(repeating: "1", count: participants.count)
        case .manual:
            let current = totalCents.map { owedCents(total: $0) } ?? Array(repeating: 0, count: participants.count)
            manualAmounts = current.map { SplitShareMath.text(fromCents: $0) }
        case .equally, .fullAmount:
            break
        }
        splitMode = mode
    }

    // MARK: - Actions

    private func save() async {
        guard let totalCents, validationMessage == nil else { return }
        isSaving = true
        defer { isSaving = false }

        let paid = paidCents(total: totalCents)
        let owed = owedCents(total: totalCents)
        var updated = expense
        updated.title = trimmedDescription
        updated.costCents = totalCents
        // Zeroes included: an edit overwrites the whole set, and dropping
        // them would make a later reopen think they were never on it.
        updated.shares = participants.indices.map {
            LedgerExpenseShare(participantID: participants[$0].id, paidCents: paid[$0], owedCents: owed[$0])
        }

        do {
            try await onSave(updated)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func delete() async {
        await onDelete()
        dismiss()
    }
}
