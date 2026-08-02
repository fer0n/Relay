//
//  TransactionDetailView.swift
//  Relay
//
//  Unified detail screen for a single transaction:
//
//  - `.draft(id:)` — routes to the editable continue flow, or explains there's
//    nothing left to do if the draft was resolved since the notification fired.
//  - `.history(_:)` — read-only summary of a created transaction/expense.
//    Re-adding stays on the row's context menu.
//  - `.pending(_:)` — read-only summary of one still waiting to be sent.
//    Retry/delete stay on the row's swipe actions.
//  - `.splitwiseExpense(_:)` — an expense fetched live from Splitwise, whose
//    total and shares can be edited back onto it. Lives in
//    SplitwiseExpenseDetailView.swift.
//

import SwiftUI
import os

private let logger = Logger(subsystem: Const.loggerSubsystem, category: "TransactionDetailView")

struct TransactionDetailView: View {
    enum Source {
        case draft(id: UUID)
        case history(TransactionHistoryEntry)
        case pending(PendingOperation)
        case splitwiseExpense(
            SplitwiseExpense,
            friendName: String,
            onSave: (SplitwiseExpenseUpdateRequest) async throws -> Void,
            onDelete: () async throws -> Void
        )
    }

    let source: Source

    var body: some View {
        switch source {
        case .draft(let id):
            DraftDetailContent(draftId: id)
        case .history(let entry):
            HistoryDetailContent(entry: entry)
        case .pending(let operation):
            PendingDetailContent(operation: operation)
        case .splitwiseExpense(let expense, let friendName, let onSave, let onDelete):
            SplitwiseExpenseDetailView(expense: expense, friendName: friendName, onSave: onSave, onDelete: onDelete)
        }
    }
}

// MARK: - Draft (editable continue flow)

private struct DraftDetailContent: View {
    let draftId: UUID

    @State private var draft: TransactionDraft?
    @State private var isLoaded = false

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let draft {
                ContinueWalletTransactionView(draft: draft, onDiscard: delete)
            } else if isLoaded {
                ContentUnavailableView(
                    "Already Handled",
                    systemImage: "checkmark.circle",
                    description: Text("This transaction was already completed or dismissed.")
                )
            } else {
                ProgressView()
            }
        }
        .task {
            draft = TransactionDraftStore.load().first { $0.id == draftId }
            isLoaded = true
        }
    }

    private func delete() {
        guard let draft else { return }
        TransactionDraftGuard.complete(draft.id)
        dismiss()
    }
}

// MARK: - Shared layout

/// Hero amount/service-icons/timestamp header plus caller-supplied sections —
/// the common shell behind `HistoryDetailContent`, `PendingDetailContent`, and
/// `SplitwiseExpenseDetailView`.
struct TransactionDetailContent<Sections: View>: View {
    let amount: String
    /// Set to make the hero amount a bound text field; nil renders plain text.
    var editableAmount: Binding<String>? = nil
    let serviceIcons: [String]
    /// Rendered as a live-updating relative time via `FuzzyDateText`, whose tick
    /// interval coarsens with age so an open sheet doesn't re-invalidate the view
    /// graph every second for a day-old transaction.
    let date: Date
    /// An icon + text line above the timestamp — e.g. Splitwise's "Paid by".
    var detailLine: (icon: String, text: String)? = nil
    /// "Discard" for a not-yet-sent operation, "Delete" for a live Splitwise
    /// expense. Only meaningful when `onDestroy` is set.
    var destroyLabel: LocalizedStringKey = "Discard"
    var destroyConfirmationTitle: LocalizedStringKey = "Discard this transaction?"
    /// Extra detail under the confirmation title — e.g. that the deletion is
    /// local-only, or that it removes the expense for everyone involved.
    var destroyConfirmationMessage: LocalizedStringKey? = nil
    /// Nil hides the destructive section entirely.
    var onDestroy: (() async -> Void)? = nil
    @ViewBuilder var sections: () -> Sections

    var body: some View {
        List {
            Section {
                VStack(spacing: 4) {
                    if let editableAmount {
                        // Same UIKit field as manual entry for the matching look,
                        // but never auto-focusing: this amount already exists,
                        // and is to be read before it's changed.
                        InstantFocusTextField(text: editableAmount, placeholder: "0", autoFocuses: false)
                            .frame(maxWidth: .infinity)
                            .frame(height: 60)
                    } else {
                        Text(amount)
                            .foregroundStyle(Color.foregroundColor)
                            .fontWeight(.heavy)
                            .font(.system(size: 50))
                            .minimumScaleFactor(0.5)
                    }
                    if let detailLine {
                        HStack(spacing: 6) {
                            Image(systemName: detailLine.icon)
                            Text(detailLine.text)
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        ForEach(serviceIcons, id: \.self) { icon in
                            Image(systemName: icon)
                        }
                        FuzzyDateText(date: date)
                            .monospacedDigit()
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.sheetBackgroundColor)

            sections()

            if let onDestroy {
                DiscardSection(
                    label: destroyLabel,
                    confirmationTitle: destroyConfirmationTitle,
                    confirmationMessage: destroyConfirmationMessage,
                    onConfirm: onDestroy
                )
            }
        }
        .themedList(background: .sheetBackgroundColor)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - History (read-only)

private struct HistoryDetailContent: View {
    let entry: TransactionHistoryEntry

    /// Resolved once at init rather than as a computed property, which would
    /// re-read the config store from disk on every keystroke in the Payee field.
    /// Nil when the entry predates `merchant` or the mapping was since removed.
    @State private var linkedInfo: WalletTransactionConfig.MerchantInfo?
    /// Editable only for a Splitwise entry with a resolvable merchant; the row is
    /// hidden otherwise.
    @State private var payeeText: String

    @Environment(\.dismiss) private var dismiss

    init(entry: TransactionHistoryEntry) {
        self.entry = entry
        let info = entry.merchant.flatMap { WalletTransactionConfigStore.load().resolvedMerchantInfo(for: $0) }
        _linkedInfo = State(initialValue: info)
        _payeeText = State(initialValue: info?.payeeName ?? "")
    }

    /// Drives the Save bar, mirroring TemplateEditView's `hasChanges`.
    private var hasPayeeChanges: Bool {
        guard let info = linkedInfo else { return false }
        let trimmed = payeeText.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed != info.payeeName
    }

    /// What the automation was handed, which the Payee row below is the tidied-up
    /// form of. Sits under the amount rather than in the card: it's what this
    /// entry *was*, like Splitwise's "Paid by", not another field of it.
    private var merchantDetailLine: (icon: String, text: String)? {
        guard let merchant = entry.merchant, !merchant.isEmpty else { return nil }
        return ("storefront", merchant)
    }

    var body: some View {
        TransactionDetailContent(
            amount: entry.formattedAmount,
            serviceIcons: [entry.service.systemImage] + (entry.secondaryService.map { [$0.systemImage] } ?? []),
            date: entry.createdAt,
            detailLine: merchantDetailLine,
            destroyLabel: "Delete",
            destroyConfirmationTitle: "Delete this transaction?",
            destroyConfirmationMessage: "This will only delete locally, YNAB/Splitwise are unaffected.",
            onDestroy: delete
        ) {
            Section {
                DraftDetailRow(icon: Const.Symbol.titleField, title: entry.service.titleFieldLabel, isEditable: false) {
                    Text(entry.title)
                }
                .cardRowBackground()

                // Description and payee are the same value at creation time, but
                // this field edits the merchant's *go-forward* mapping rather
                // than the frozen entry.
                if entry.service == .splitwise, let info = linkedInfo {
                    DraftDetailRow(icon: Const.Symbol.template, title: "Template", isEditable: false) {
                        Text(info.templateName)
                    }
                    .cardRowBackground()

                    DraftDetailRow(icon: "person.text.rectangle", title: "Payee") {
                        TextField("Payee", text: $payeeText)
                            .multilineTextAlignment(.trailing)
                            .submitLabel(.done)
                            .autocorrectionDisabled()
                    }
                    .cardRowBackground()
                }

                if let categoryName = entry.categoryName {
                    DraftDetailRow(icon: Const.Symbol.category, title: "Category", isEditable: false) {
                        Text(categoryName)
                    }
                    .cardRowBackground()
                }

                if let accountName = entry.accountName {
                    DraftDetailRow(icon: Const.Symbol.account, title: "Account", isEditable: false) {
                        Text(accountName)
                    }
                    .cardRowBackground()
                }
            }

            if let splitSummary = entry.splitSummary {
                Section("Split") {
                    DraftDetailRow(icon: Const.Symbol.friends, title: "With", isEditable: false) {
                        Text(splitSummary)
                    }
                    .cardRowBackground()
                }
            }

            // Runs dropped as duplicates of this one (see TransactionClaim) — the
            // only place the dedupe is inspectable after the fact, and each run's
            // merchant string is what shows whether the match was right.
            if !entry.suppressed.isEmpty {
                Section("Duplicates Skipped") {
                    ForEach(entry.suppressed) { run in
                        DraftDetailRow(icon: Const.Symbol.duplicateSkipped, title: "Also seen from", isEditable: false) {
                            Text(run.merchant == entry.merchant ? run.source : "\(run.source) · \(run.merchant)")
                        }
                        .cardRowBackground()
                    }
                }
            }
        }
        .bottomBarActionButton(isPresented: hasPayeeChanges, title: "Save", action: savePayee)
    }

    private func delete() async {
        TransactionHistoryStore.delete(id: entry.id)
        dismiss()
    }

    private func savePayee() {
        guard let merchant = entry.merchant, let info = linkedInfo else { return }
        let trimmed = payeeText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var config = WalletTransactionConfigStore.load()
        guard config.linkMerchantIfChanged(merchant: merchant, payeeName: trimmed, templateName: info.templateName) else { return }
        do {
            try WalletTransactionConfigStore.save(config)
            linkedInfo = WalletTransactionConfig.MerchantInfo(payeeName: trimmed, templateName: info.templateName)
            // Description and payee started out equal (see the comment on the
            // Payee row above) — carry the rename onto this and any other
            // frozen entry from the same merchant, rather than leaving
            // "Recent" rows showing the stale name.
            TransactionHistoryStore.updateTitles(forMerchant: merchant, title: trimmed)
            dismiss()
        } catch {
            logger.error("failed to save edited payee: \(String(describing: error), privacy: .public)")
        }
    }
}

// MARK: - Pending (read-only)

private struct PendingDetailContent: View {
    let operation: PendingOperation

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TransactionDetailContent(
            amount: operation.payload.formattedAmount,
            serviceIcons: [operation.service.systemImage],
            date: operation.queuedAt,
            onDestroy: discard
        ) {
            Section {
                DraftDetailRow(icon: Const.Symbol.titleField, title: operation.service.titleFieldLabel, isEditable: false) {
                    Text(operation.payload.title)
                }
                .cardRowBackground()

                if let detail = operation.payload.detail {
                    DraftDetailRow(icon: operation.service == .ynab ? Const.Symbol.category : Const.Symbol.friends, title: operation.service == .ynab ? "Category" : "With", isEditable: false) {
                        Text(detail)
                    }
                    .cardRowBackground()
                }
            }

            if let lastError = operation.lastError {
                Section("Last Error") {
                    DraftDetailRow(icon: Const.Symbol.syncError, title: "Attempt \(operation.attemptCount)", isEditable: false) {
                        Text(lastError)
                    }
                    .cardRowBackground()
                }
            }
        }
    }

    private func discard() {
        PendingOperationQueue.shared.delete(id: operation.id)
        dismiss()
    }
}

#Preview("Draft") {
    let draft = TransactionDraft(
        id: UUID(),
        startedAt: Date().addingTimeInterval(-3600),
        payload: .ynabWallet(merchant: "Coffee Shop", amount: 4.50, card: "Visa")
    )
    Color.clear
        .onAppear { try? TransactionDraftStore.save([draft]) }
        .sheet(isPresented: .constant(true)) {
            NavigationStack {
                TransactionDetailView(source: .draft(id: draft.id))
            }
        }
}

#Preview("History") {
    let entry = TransactionHistoryEntry(
        id: UUID(),
        createdAt: Date().addingTimeInterval(-3600),
        summary: "12.34 at Coffee Shop",
        payload: .ynabTransaction(YNABTransactionRequest(
            accountId: "acct",
            date: "2026-07-21",
            amount: -12340,
            payeeName: "Coffee Shop",
            categoryId: nil,
            cleared: Const.YNAB.cleared,
            approved: true
        ))
    )
    Color.clear
        .sheet(isPresented: .constant(true)) {
            NavigationStack {
                TransactionDetailView(source: .history(entry))
            }
        }
}
