//
//  LedgerRecordPaymentView.swift
//  Relay
//
//  Who paid whom, and how much. The settle-up plan survives only as
//  suggestions that fill the form in — a part payment, or paying someone the
//  plan routed around, has to be recordable too.
//

import SwiftUI

struct LedgerRecordPaymentView: View {
    let ledger: Ledger
    let balances: LedgerBalances
    let onRecord: (LedgerSettlement) async -> Void

    @State private var payerID: String
    @State private var recipientID: String
    @State private var amount: String
    /// Once typed into, changing a party stops overwriting it.
    @State private var hasEditedAmount = false
    @State private var isSaving = false
    @FocusState private var isAmountFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(
        ledger: Ledger,
        balances: LedgerBalances,
        onRecord: @escaping (LedgerSettlement) async -> Void
    ) {
        self.ledger = ledger
        self.balances = balances
        self.onRecord = onRecord

        let people = Self.people(in: ledger)
        // Most payments are a leg of the plan, usually the reader's own.
        let suggested = balances.settlements.first { settlement in
            settlement.from == ledger.currentUserID || settlement.to == ledger.currentUserID
        } ?? balances.settlements.first
        _payerID = State(initialValue: suggested?.from ?? ledger.currentUserID ?? people.first?.id ?? "")
        _recipientID = State(initialValue: suggested?.to ?? people.first { $0.id != ledger.currentUserID }?.id ?? "")
        _amount = State(initialValue: suggested.map { SplitShareMath.text(fromCents: $0.cents) } ?? "")
    }

    var body: some View {
        List {
            Section {
                participantRow(title: "From", selection: $payerID, excluding: recipientID)
                participantRow(title: "To", selection: $recipientID, excluding: payerID)
                amountRow
            } footer: {
                Text(outstandingDescription)
                    .footerText()
            }
            .cardRowBackground()

            if !suggestions.isEmpty {
                suggestionsSection
            }
        }
        .themedList(background: .sheetBackgroundColor)
        .navigationTitle("Record Payment")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Record") { record() }
                    .disabled(settlement == nil || isSaving)
            }
        }
    }

    private var people: [LedgerParticipant] { Self.people(in: ledger) }

    /// A payment to yourself isn't one.
    private func participantRow(
        title: LocalizedStringKey,
        selection: Binding<String>,
        excluding otherID: String
    ) -> some View {
        DraftDetailRow(
            icon: Const.Symbol.person,
            title: title,
            isIncomplete: ledger.participant(id: selection.wrappedValue) == nil
        ) {
            MenuPickerField(
                selection: Binding(
                    get: { selection.wrappedValue },
                    set: {
                        selection.wrappedValue = $0
                        refillAmount()
                    }
                ),
                label: name(of: selection.wrappedValue)
            ) {
                ForEach(people.filter { $0.id != otherID }) { participant in
                    Text(participant.displayName).tag(participant.id)
                }
            }
        }
    }

    /// `.decimalPad` has no return key, hence `dismissButtonToolbar`.
    private var amountRow: some View {
        DraftDetailRow(
            icon: Const.Symbol.account,
            title: "Amount",
            isIncomplete: (SplitShareMath.cents(amount) ?? 0) <= 0
        ) {
            TextField("0", text: $amount)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .focused($isAmountFocused)
                .dismissButtonToolbar(isFocused: $isAmountFocused)
                .onChange(of: amount) { _, _ in
                    if isAmountFocused { hasEditedAmount = true }
                }
        }
    }

    /// Taps that fill the form in, not writes: what was paid is the user's
    /// to confirm.
    private var suggestionsSection: some View {
        Section {
            ForEach(suggestions, id: \.self) { suggestion in
                Button {
                    payerID = suggestion.from
                    recipientID = suggestion.to
                    amount = SplitShareMath.text(fromCents: suggestion.cents)
                    hasEditedAmount = false
                } label: {
                    HStack {
                        Text(paysDescription(suggestion))
                        Spacer()
                        Text(money(suggestion.cents))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Suggested")
        } footer: {
            Text("The fewest payments that settle everyone — a debt that routes through someone else is collapsed into one transfer.")
                .footerText()
        }
        .cardRowBackground()
    }

    private var suggestions: [LedgerSettlement] { balances.settlements }

    /// Nil while the form can't describe a payment; the Record button reads
    /// this rather than repeating the rules.
    private var settlement: LedgerSettlement? {
        guard payerID != recipientID,
              ledger.participant(id: payerID) != nil,
              ledger.participant(id: recipientID) != nil,
              let cents = SplitShareMath.cents(amount), cents > 0 else { return nil }
        return LedgerSettlement(from: payerID, to: recipientID, cents: cents)
    }

    /// What the two owe each other today, to judge a part payment against.
    private var outstandingDescription: String {
        guard payerID != recipientID else { return "" }
        let owed = balances.cents(me: recipientID, other: payerID, simplified: ledger.simplifiesDebts)
        guard owed != 0 else { return String(localized: "Nothing outstanding between them.") }
        let debtor = owed > 0 ? payerID : recipientID
        let creditor = owed > 0 ? recipientID : payerID
        return owesDescription(debtor: debtor, creditor: creditor, cents: abs(owed))
    }

    /// "You owe" vs "Alex owes" — each side needs its own template rather
    /// than one substituted into.
    private func owesDescription(debtor: String, creditor: String, cents: Int) -> String {
        let amount = money(cents)
        if debtor == ledger.currentUserID {
            return String(localized: "You owe \(name(of: creditor)) \(amount).")
        }
        if creditor == ledger.currentUserID {
            return String(localized: "\(name(of: debtor)) owes you \(amount).")
        }
        return String(localized: "\(name(of: debtor)) owes \(name(of: creditor)) \(amount).")
    }

    /// Same conjugation problem as `owesDescription`.
    private func paysDescription(_ suggestion: LedgerSettlement) -> String {
        if suggestion.from == ledger.currentUserID {
            return String(localized: "You pay \(name(of: suggestion.to))")
        }
        if suggestion.to == ledger.currentUserID {
            return String(localized: "\(name(of: suggestion.from)) pays you")
        }
        return String(localized: "\(name(of: suggestion.from)) pays \(name(of: suggestion.to))")
    }

    private func refillAmount() {
        guard !hasEditedAmount else { return }
        let owed = balances.cents(me: recipientID, other: payerID, simplified: ledger.simplifiesDebts)
        amount = owed > 0 ? SplitShareMath.text(fromCents: owed) : ""
    }

    private func name(of participantID: String) -> String {
        ledger.participant(id: participantID)?.displayName ?? LedgerParticipant.unknownName
    }

    private func money(_ cents: Int) -> String {
        cents.asMoney(ledger.currencyCode)
    }

    private func record() {
        guard let settlement, !isSaving else { return }
        isSaving = true
        Task {
            await onRecord(settlement)
            dismiss()
        }
    }

    /// Pending invitees can't see the ledger, so a payment naming one could
    /// never be seen by both sides.
    private static func people(in ledger: Ledger) -> [LedgerParticipant] {
        ledger.participants.filter(\.hasAccepted)
    }
}
