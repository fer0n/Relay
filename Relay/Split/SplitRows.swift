//
//  SplitRows.swift
//  Relay
//
//  Rows shared by ContinueWalletTransactionView's "Split" sections. The two
//  draft kinds differ in row order and gating, so each still assembles its own
//  section; only the rows are shared.
//

import SwiftUI

/// Read-only once a template's setting is resolved, otherwise a picker.
struct SplitOptionRow: View {
    var title: LocalizedStringKey
    let isResolved: Bool
    let resolvedOption: SplitTemplateOption
    @Binding var newOption: SplitTemplateOption

    var body: some View {
        DraftDetailRow(icon: "divide.circle.fill", title: title, isEditable: !isResolved) {
            if isResolved {
                Text(resolvedOption.label)
            } else {
                MenuPickerField(selection: $newOption, label: newOption.label) {
                    ForEach([SplitTemplateOption.ask, .always, .manual, .never], id: \.self) { option in
                        Text(option.label).tag(option)
                    }
                }
            }
        }
        .cardRowBackground()
    }
}

/// For the screens that store exactly one target. The draft forms use
/// `LedgerParticipantPickerRow`, which can name several people.
struct SplitTargetPickerRow: View {
    let isLoading: Bool
    var ledgers: [Ledger] = []
    @Binding var target: WalletTransactionConfig.CachedSplitTarget?
    /// TemplateEditView passes "Default (…)" where one applies.
    var noneLabel: String = "None"
    var isIncomplete: Bool = false

    var body: some View {
        DraftDetailRow(icon: Const.Symbol.friends, title: "Split With", isIncomplete: isIncomplete) {
            if isLoading, ledgers.isEmpty {
                ProgressView()
            } else {
                SplitTargetMenu(ledgers: ledgers, noneLabel: noneLabel) { target = $0 } label: {
                    // The stored name, not a lookup: a ledger that hasn't
                    // loaded yet would otherwise show the row as unset while
                    // it isn't.
                    Text(target?.fullName ?? noneLabel)
                }
            }
        }
        .cardRowBackground()
    }
}

/// Pre-filled from the template's split setting. `nil` means "Ask Each Time"
/// and the user still has to choose.
struct SplitPickerRow: View {
    @Binding var choice: SplitChoice?
    var isIncomplete: Bool = false

    var body: some View {
        DraftDetailRow(
            icon: "divide.circle.fill",
            title: "Split",
            isIncomplete: isIncomplete
        ) {
            MenuPickerField(
                selection: $choice,
                label: choice?.label ?? "Choose"
            ) {
                Text("Choose").tag(SplitChoice?.none)
                ForEach([SplitChoice.always, .shares, .manual, .never], id: \.self) { option in
                    Text(option.label).tag(SplitChoice?.some(option))
                }
            }
        }
        .cardRowBackground()
    }
}

/// One participant's weight in a `.shares` split, with the amount it works
/// out to underneath. Its own view for the per-field `@FocusState`.
struct ShareWeightRow: View {
    let name: String
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
                .foregroundStyle(SplitShareMath.cents(weight) == nil ? Color.accentColor : Color.primary)
                .dismissButtonToolbar(isFocused: $isFocused)
        }
        .padding(.vertical, 3)
        .cardRowBackground()
    }
}

struct OwnShareRow: View {
    @Binding var ownShareText: String
    var isIncomplete: Bool = false

    @FocusState private var isFocused: Bool

    var body: some View {
        DraftDetailRow(
            icon: "eurosign.circle.fill",
            title: "Your Share",
            isIncomplete: isIncomplete
        ) {
            TextField("Your Share", text: $ownShareText)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .dismissButtonToolbar(isFocused: $isFocused)
        }
        .cardRowBackground()
    }
}
