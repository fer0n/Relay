//
//  SplitwiseExpenseDetailView.swift
//  Relay
//
//  Detail screen for one expense fetched live from Splitwise, reached from a
//  row in SplitwiseFriendTransactionsView (via TransactionDetailView's
//  `.splitwiseExpense` source, whose shared layout this reuses).
//
//  Unlike the other detail screens this one edits, and saves back to
//  Splitwise: the description, the total, who paid, and how it's split. Every
//  amount Splitwise stores is *derived* from a few inputs here rather than
//  typed per person, which is what keeps the numbers it insists on adding up:
//
//  - Total is the whole cost. The single payer is taken to have fronted all
//    of it (Relay only ever creates single-payer expenses, and that's the
//    usual shape of one anyway).
//  - Split decides how the cost is divided into what each participant owes:
//    - Equally — the cost split into equal shares.
//    - Full amount — the payer owes nothing and the other participant owes
//      all of it. Only offered for a two-person expense, where "the other
//      one" is unambiguous.
//    - Shares — each participant is given a relative weight, and the cost is
//      divided in proportion to them. Amounts, not weights, are what Splitwise
//      stores, so the weights live only here.
//
//  Splitwise records none of this — only the final per-person amounts — so on
//  open the mode is *inferred* back from them (an even split reads as Equally,
//  and so on), and everything downstream recomputes from the inputs. All of
//  the arithmetic lives in SplitwiseShareMath so it stays testable on its own.
//

import SwiftUI

struct SplitwiseExpenseDetailView: View {
    let expense: SplitwiseExpense
    let friendName: String
    /// Saves the edit to Splitwise and refreshes whatever the caller shows —
    /// see SplitwiseFriendTransactionsView.update(_:with:).
    let onSave: (SplitwiseExpenseUpdateRequest) async throws -> Void
    let onDelete: () async throws -> Void

    /// How the cost is divided into what each participant owes. Splitwise
    /// stores only the resulting amounts, so this is inferred on open and
    /// never round-trips as itself.
    private enum SplitMode: Hashable {
        case equally
        /// The payer owes nothing, the other participant owes all of it. Only
        /// meaningful — and only offered — for exactly two participants.
        case fullAmount
        case shares
        /// The amounts are typed in directly and have to add up to the total
        /// themselves — no derivation. What a reopened custom split comes back
        /// as, since it's the mode that can represent any set of amounts.
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

    /// One participant's identity: `userId` is what Splitwise needs back on
    /// save, `name` the display label ("You", or the participant's own name).
    private struct Participant {
        let userId: Int
        let name: String
    }

    @State private var totalText: String
    @State private var descriptionText: String
    /// Index into `participants` of the single payer, who fronted the whole
    /// total.
    @State private var payer: Int
    @State private var splitMode: SplitMode
    /// Per-participant relative weights, positionally matching `participants`.
    /// Only read in `.shares` mode; reset to an even 1-each whenever that mode
    /// is picked, so a shares split starts from equal weights to adjust.
    @State private var weights: [String]
    /// Per-participant typed amounts, positionally matching `participants`.
    /// Only read in `.manual` mode; seeded from the current split whenever that
    /// mode is entered, and from the stored amounts for a reopened custom
    /// split, so both start from real numbers to edit rather than a blank slate.
    @State private var manualAmounts: [String]
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var showDeleteError = false

    private let participants: [Participant]
    private let originalTotalCents: Int?
    private let originalOwedCents: [Int]
    private let originalPaidCents: [Int]

    @Environment(\.dismiss) private var dismiss

    init(
        expense: SplitwiseExpense,
        friendName: String,
        onSave: @escaping (SplitwiseExpenseUpdateRequest) async throws -> Void,
        onDelete: @escaping () async throws -> Void
    ) {
        self.expense = expense
        self.friendName = friendName
        self.onSave = onSave
        self.onDelete = onDelete

        let currentUserId = SplitwiseCurrentUserStore.load()?.id
        // Every participant, not just the ones with a nonzero share: an edit
        // overwrites all of Splitwise's shares at once, so anyone left out
        // here would silently drop off the expense.
        let people = expense.users.map {
            Participant(userId: $0.userId, name: $0.label(currentUserId: currentUserId, fallback: friendName))
        }
        let owed = expense.users.map { SplitwiseShareMath.cents(fromAmount: $0.owedShare ?? 0) }
        let paid = expense.users.map { SplitwiseShareMath.cents(fromAmount: $0.paid ?? 0) }
        // Whoever fronted the most is treated as the payer. For the usual
        // single-payer expense that's simply them; for the rare multi-payer
        // one it collapses to the main payer, which the Save bar then surfaces
        // as a change (the paid amounts no longer match).
        let payerIndex = paid.indices.max(by: { paid[$0] < paid[$1] }) ?? 0
        let cost = Double(expense.cost).map { SplitwiseShareMath.cents(fromAmount: $0) }

        participants = people
        originalTotalCents = cost
        originalOwedCents = owed
        originalPaidCents = paid

        _totalText = State(initialValue: cost.map { SplitwiseShareMath.text(fromCents: $0) } ?? expense.cost)
        _descriptionText = State(initialValue: expense.description)
        _payer = State(initialValue: payerIndex)
        _splitMode = State(initialValue: Self.inferMode(totalCents: cost, owedCents: owed, payer: payerIndex))
        // Weights aren't inferred — a custom split reopens as `.manual` — so
        // they only ever start from the even 1-each that picking Shares resets
        // them to anyway.
        _weights = State(initialValue: Array(repeating: "1", count: people.count))
        // Seeded from the amounts on file so an inferred `.manual` split
        // round-trips exactly; reseeded from the current split when `.manual`
        // is picked from another mode.
        _manualAmounts = State(initialValue: owed.map { SplitwiseShareMath.text(fromCents: $0) })
    }

    /// Reads a split mode back from the amounts Splitwise stored, since it
    /// keeps no record of which one produced them: an even division is
    /// Equally, a two-person "one owes everything" is Full amount, anything
    /// else is a custom split — which comes back as Manual (its typed amounts),
    /// the mode that can represent any arbitrary split.
    private static func inferMode(totalCents: Int?, owedCents: [Int], payer: Int) -> SplitMode {
        guard let total = totalCents, total > 0 else { return .equally }
        let count = owedCents.count
        if owedCents == SplitwiseShareMath.distribute(totalCents: total, ratios: SplitwiseShareMath.evenRatios(count: count)) {
            return .equally
        }
        if count == 2, owedCents == (0..<2).map({ $0 == payer ? 0 : total }) {
            return .fullAmount
        }
        return .manual
    }

    // MARK: - Derived state

    private var totalCents: Int? { SplitwiseShareMath.cents(totalText) }

    private var trimmedDescription: String {
        descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What each participant owes, derived from the total and split mode — the
    /// amounts Splitwise actually stores. Always adds up to `total` exactly,
    /// which is what Splitwise validates.
    private func owedCents(total: Int) -> [Int] {
        switch splitMode {
        case .equally:
            return SplitwiseShareMath.distribute(
                totalCents: total,
                ratios: SplitwiseShareMath.evenRatios(count: participants.count)
            )
        case .fullAmount:
            // Only reachable with two participants (see the picker): the
            // non-payer owes all of it.
            return participants.indices.map { $0 == payer ? 0 : total }
        case .shares:
            let values = weights.map { Double(SplitwiseShareMath.cents($0) ?? 0) }
            return SplitwiseShareMath.distribute(totalCents: total, ratios: SplitwiseShareMath.ratios(of: values))
        case .manual:
            // Taken straight off the fields — the one mode whose amounts aren't
            // guaranteed to add up, which `validationMessage` enforces instead.
            return manualAmounts.map { SplitwiseShareMath.cents($0) ?? 0 }
        }
    }

    /// What each participant fronted: the single payer covers the whole total,
    /// everyone else nothing.
    private func paidCents(total: Int) -> [Int] {
        participants.indices.map { $0 == payer ? total : 0 }
    }

    /// Whether the per-participant inputs a split mode carries are all
    /// parseable — nothing for the modes that derive straight from the total,
    /// every weight (with at least one nonzero) for `.shares`, and every amount
    /// for `.manual`. Whether the manual amounts actually *add up* is a
    /// `validationMessage` concern, not this one.
    private var splitInputsValid: Bool {
        switch splitMode {
        case .equally, .fullAmount:
            return true
        case .shares:
            let parsed = weights.map { SplitwiseShareMath.cents($0) }
            guard !parsed.contains(where: { $0 == nil }) else { return false }
            return parsed.compactMap { $0 }.reduce(0, +) > 0
        case .manual:
            return !manualAmounts.contains { SplitwiseShareMath.cents($0) == nil }
        }
    }

    /// Whether anything on screen differs from the expense as Splitwise has
    /// it — drives the Save bar, same as TemplateEditView's `hasChanges`. An
    /// unparseable field counts as a change so the bar appears (disabled)
    /// with the reason below it, rather than leaving a broken value looking
    /// accepted.
    private var hasChanges: Bool {
        if trimmedDescription != expense.description { return true }
        guard let totalCents else { return true }
        if totalCents != originalTotalCents { return true }
        if paidCents(total: totalCents) != originalPaidCents { return true }
        guard splitInputsValid else { return true }
        return owedCents(total: totalCents) != originalOwedCents
    }

    /// Why this edit can't be saved yet, or nil when it can.
    private var validationMessage: String? {
        guard !trimmedDescription.isEmpty else {
            return String(localized: "Enter a description.")
        }
        guard let totalCents, totalCents > 0 else {
            return String(localized: "Enter a valid total.")
        }
        if splitMode == .shares {
            let parsed = weights.map { SplitwiseShareMath.cents($0) }
            guard !parsed.contains(where: { $0 == nil }) else {
                return String(localized: "Enter a valid share for everyone.")
            }
            guard parsed.compactMap({ $0 }).reduce(0, +) > 0 else {
                return String(localized: "Give at least one person a share.")
            }
        }
        if splitMode == .manual {
            let parsed = manualAmounts.map { SplitwiseShareMath.cents($0) }
            guard !parsed.contains(where: { $0 == nil }) else {
                return String(localized: "Enter a valid amount for everyone.")
            }
            let sum = parsed.compactMap { $0 }.reduce(0, +)
            guard sum == totalCents else {
                let sumText = SplitwiseShareMath.text(fromCents: sum)
                let expectedText = SplitwiseShareMath.text(fromCents: totalCents)
                return String(localized: "The amounts add up to \(sumText), but the total is \(expectedText).")
            }
        }
        return nil
    }

    /// What "Remaining" fills into participant `index`'s manual field: the
    /// total minus everyone else's amount. Nil when it can't be worked out —
    /// an unparseable total or some other field still mid-typing.
    private func manualRemaining(forIndex index: Int, total: Int) -> Int? {
        var others = 0
        for (position, text) in manualAmounts.enumerated() where position != index {
            guard let value = SplitwiseShareMath.cents(text) else { return nil }
            others += value
        }
        return total - others
    }

    /// The "paid by" line under the amount. Reads the picked payer rather than
    /// the expense as it arrived, so it can't sit there contradicting a payer
    /// the user just changed.
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
            serviceIcons: [TransactionService.splitwise.systemImage],
            date: expense.date,
            detailLine: payerDetailLine,
            destroyLabel: "Delete",
            destroyConfirmationTitle: "Delete this expense?",
            destroyConfirmationMessage: "This will delete the expense on Splitwise for everyone involved.",
            onDestroy: delete
        ) {
            Section {
                DraftDetailRow(icon: Const.Symbol.titleField, title: "Description") {
                    TextField("Description", text: $descriptionText)
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

                DraftDetailRow(icon: "person.2.fill", title: "Split") {
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

                // Each participant's amount is shown in every mode. `.shares`
                // and `.manual` make it editable — a weight that produces the
                // amount, or the amount itself — while the derived modes just
                // show the figure.
                ForEach(participants.indices, id: \.self) { index in
                    let amount = owedNow.map { SplitwiseShareMath.text(fromCents: $0[index]) }
                    switch splitMode {
                    case .shares:
                        ShareWeightRow(
                            name: participants[index].name,
                            amountText: amount,
                            weight: $weights[index]
                        )
                    case .manual:
                        ManualAmountRow(
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

                AmountFieldRow(icon: "sum", title: "Total", text: $totalText)
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
        .alert("Couldn't Save", isPresented: .init(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            if let saveError {
                Text(saveError)
            }
        }
        .alert("Couldn't Delete", isPresented: $showDeleteError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Please check your connection and try again.")
        }
    }

    // MARK: - Editing

    /// Switches split mode, seeding whatever fields the new one owns:
    /// - `.shares` starts everyone at a weight of 1 — an even split to adjust
    ///   from — rather than inheriting the amounts that were on screen.
    /// - `.manual` starts from the split currently shown, so the fields open
    ///   on real amounts (that already add up) to tweak.
    /// A custom split that *arrived* this way is instead handled in `init`,
    /// which seeds the manual amounts from what Splitwise stored.
    private func setMode(_ mode: SplitMode) {
        switch mode {
        case .shares:
            weights = Array(repeating: "1", count: participants.count)
        case .manual:
            let current = totalCents.map { owedCents(total: $0) } ?? Array(repeating: 0, count: participants.count)
            manualAmounts = current.map { SplitwiseShareMath.text(fromCents: $0) }
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
        let request = SplitwiseExpenseUpdateRequest(
            costCents: totalCents,
            description: trimmedDescription,
            currencyCode: expense.currencyCode,
            groupId: expense.groupId ?? 0,
            users: participants.indices.map {
                SplitwiseExpenseUpdateRequest.UserShare(
                    userId: participants[$0].userId,
                    paidCents: paid[$0],
                    owedCents: owed[$0]
                )
            }
        )

        do {
            try await onSave(request)
            dismiss()
        } catch SplitwiseAPIError.validation(let message) {
            // Splitwise's own wording for a rejected edit — more useful than
            // a generic failure, since it names what it didn't like.
            saveError = message
        } catch {
            saveError = String(localized: "Please check your connection and try again.")
        }
    }

    private func delete() async {
        do {
            try await onDelete()
            dismiss()
        } catch {
            showDeleteError = true
        }
    }
}

/// A labeled decimal-pad amount field (the Total row). Its own view so it owns
/// the `@FocusState` that `dismissButtonToolbar` needs — `.decimalPad` has no
/// return key — the same way the share rows below do.
private struct AmountFieldRow: View {
    let icon: String
    let title: LocalizedStringKey
    @Binding var text: String

    @FocusState private var isFocused: Bool

    var body: some View {
        DraftDetailRow(
            icon: icon,
            title: title,
            isIncomplete: SplitwiseShareMath.cents(text) == nil
        ) {
            TextField("0", text: $text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .dismissButtonToolbar(isFocused: $isFocused)
        }
        .cardRowBackground()
    }
}

/// A `.shares` row: the participant's name with the amount their weight works
/// out to underneath, and the weight itself as a decimal-pad field. Its own
/// view so each field owns the `@FocusState` `dismissButtonToolbar` needs, the
/// same way SplitwiseOwnShareRow does for the draft forms.
private struct ShareWeightRow: View {
    let name: String
    /// What this participant's weight currently divides out to, shown as a
    /// hint under the name; nil while the total is unparseable.
    let amountText: String?
    @Binding var weight: String

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: Const.Symbol.person)
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .padding(.trailing, 12)

            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .foregroundStyle(.secondary)
                if let amountText {
                    Text(amountText)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
            .lineLimit(1)

            Spacer(minLength: 10)

            TextField("0", text: $weight)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .foregroundStyle(SplitwiseShareMath.cents(weight) == nil ? Color.accentColor : Color.primary)
                .dismissButtonToolbar(isFocused: $isFocused)
        }
        .padding(.vertical, 3)
        .cardRowBackground()
    }
}

/// A `.manual` row: the participant's name and their owed amount typed in
/// directly. While focused its keyboard carries a "Remaining" button that
/// fills in whatever's left of the total after the others — the quick way to
/// settle the last person so the amounts add up. Its own view both for the
/// per-field `@FocusState` (`dismissButtonToolbar`'s job is folded into that
/// toolbar here) and so that focus scopes the toolbar to this one field.
private struct ManualAmountRow: View {
    let name: String
    @Binding var amount: String
    /// What "Remaining" would fill in — the total minus everyone else — or nil
    /// when it can't be computed. Negative (the others already overshoot the
    /// total) disables the button rather than offering an invalid amount.
    let remaining: Int?

    @FocusState private var isFocused: Bool

    var body: some View {
        DraftDetailRow(
            icon: Const.Symbol.person,
            title: "\(name)",
            isIncomplete: SplitwiseShareMath.cents(amount) == nil
        ) {
            TextField("0", text: $amount)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .focused($isFocused)
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        if isFocused {
                            remainingToolbar
                        }
                    }
                }
        }
        .cardRowBackground()
    }

    @ViewBuilder
    private var remainingToolbar: some View {
        Button {
            if let remaining, remaining >= 0 {
                amount = SplitwiseShareMath.text(fromCents: remaining)
            }
        } label: {
            if let remaining {
                Text("Remaining \(SplitwiseShareMath.text(fromCents: remaining))")
            } else {
                Text("Remaining")
            }
        }
        .disabled((remaining ?? -1) < 0)

        Spacer()

        Button {
            isFocused = false
        } label: {
            Image(systemName: Const.Symbol.dismissKeyboard)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    let expense = SplitwiseExpense(
        id: 1,
        description: "Groceries",
        cost: "42.00",
        currencyCode: "EUR",
        date: Date().addingTimeInterval(-7200),
        deletedAt: nil,
        users: [
            SplitwiseExpenseUser(
                userId: 1,
                paidShare: "42.00",
                netBalance: "21.00",
                user: SplitwiseExpenseParticipant(firstName: "Sam", lastName: "Rivera")
            ),
            SplitwiseExpenseUser(
                userId: 2,
                paidShare: "0.00",
                netBalance: "-21.00",
                user: SplitwiseExpenseParticipant(firstName: "Alex", lastName: "Kim")
            ),
        ],
        groupId: 0
    )
    return NavigationStack {
        SplitwiseExpenseDetailView(expense: expense, friendName: "Alex K.", onSave: { _ in }, onDelete: {})
    }
}
