//
//  TransactionDetailView.swift
//  Relay
//
//  Unified detail screen for a single transaction, reached two ways:
//
//  - `.draft(id:)` — a tapped "Continue Adding Transaction" notification (or
//    a draft row in TransactionDraftsView): loads the draft by id and routes
//    to the editable continue flow (ContinueWalletTransactionView), or
//    explains there's nothing left to do if it's already been resolved
//    (completed elsewhere, or dismissed) since the notification fired.
//  - `.history(_:)` — a tapped row in ContentView's "Recent" list: a
//    read-only summary of an already-created YNAB transaction and/or
//    Splitwise expense. No editing — re-adding stays on the row's context
//    menu.
//  - `.pending(_:)` — a tapped row in PendingQueueView: a read-only summary
//    of a YNAB transaction or Splitwise expense still waiting to be sent.
//    Retry/delete stay on the row's swipe actions.
//  - `.splitwiseExpense(_:)` — a tapped row in
//    SplitwiseFriendTransactionsView: a read-only summary of an expense
//    fetched live from Splitwise (rather than one Relay itself created).
//

import SwiftUI
import os

private let logger = Logger(subsystem: "com.octabits.relay", category: "TransactionDetailView")

struct TransactionDetailView: View {
    enum Source {
        case draft(id: UUID)
        case history(TransactionHistoryEntry)
        case pending(PendingOperation)
        case splitwiseExpense(SplitwiseExpense, friendName: String, onDelete: () async throws -> Void)
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
        case .splitwiseExpense(let expense, let friendName, let onDelete):
            SplitwiseExpenseDetailContent(expense: expense, friendName: friendName, onDelete: onDelete)
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

// MARK: - Shared read-only layout

/// Hero amount/service-icons/timestamp header, plus caller-supplied detail
/// sections — the common shell behind `HistoryDetailContent`,
/// `PendingDetailContent`, and `SplitwiseExpenseDetailContent`.
private struct ReadOnlyDetailContent<Sections: View>: View {
    let amount: String
    let serviceIcons: [String]
    /// When this transaction happened — shown as a single-unit relative time
    /// (e.g. "1 day ago") alongside `serviceIcons`, live-updating via
    /// `FuzzyDateText`. Its schedule backs off to a coarser tick interval
    /// once the near-term buckets are past, so an open detail sheet doesn't
    /// re-invalidate the view graph every second for a day-old transaction.
    let date: Date
    /// An optional icon + text line shown above the service-icons/timestamp
    /// line — e.g. Splitwise's "Paid by" line. Nil shows nothing.
    var detailLine: (icon: String, text: String)? = nil
    /// Row label + confirmation wording for the destructive action at the
    /// bottom — "Discard" for a not-yet-sent operation, "Delete" for a live
    /// Splitwise expense. Only meaningful when `onDestroy` is set.
    var destroyLabel: LocalizedStringKey = "Discard"
    var destroyConfirmationTitle: LocalizedStringKey = "Discard this transaction?"
    /// Called when the user confirms the destructive action. Nil hides the
    /// section entirely (e.g. history, which can't be discarded or deleted).
    var onDestroy: (() async -> Void)? = nil
    @ViewBuilder var sections: () -> Sections

    var body: some View {
        List {
            Section {
                VStack(spacing: 4) {
                    Text(amount)
                        .foregroundStyle(Color.foregroundColor)
                        .fontWeight(.heavy)
                        .font(.system(size: 50))
                        .minimumScaleFactor(0.5)
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
                DiscardSection(label: destroyLabel, confirmationTitle: destroyConfirmationTitle, onConfirm: onDestroy)
            }
        }
        .themedList(background: .sheetBackgroundColor)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - History (read-only)

private struct HistoryDetailContent: View {
    let entry: TransactionHistoryEntry

    /// The merchant's Payee/Template mapping as of when this screen opened —
    /// resolved once at init (rather than a computed property re-reading
    /// WalletTransactionConfigStore from disk on every body evaluation, e.g.
    /// each keystroke in the Payee field) and refreshed in-place after a
    /// successful save. Nil when the entry predates `merchant` being
    /// recorded, or the mapping was since removed — either way there's
    /// nothing to show or edit.
    @State private var linkedInfo: WalletTransactionConfig.MerchantInfo?
    /// Seeded once at init from `linkedInfo`'s payee name. Editable only for
    /// a Splitwise entry with a resolvable merchant; unused (and the row
    /// hidden) otherwise.
    @State private var payeeText: String

    @Environment(\.dismiss) private var dismiss

    init(entry: TransactionHistoryEntry) {
        self.entry = entry
        let info = entry.merchant.flatMap { WalletTransactionConfigStore.load().resolvedMerchantInfo(for: $0) }
        _linkedInfo = State(initialValue: info)
        _payeeText = State(initialValue: info?.payeeName ?? "")
    }

    /// Whether the typed Payee differs from what's currently on record —
    /// drives the Save bar, mirroring TemplateEditView's `hasChanges`.
    private var hasPayeeChanges: Bool {
        guard let info = linkedInfo else { return false }
        let trimmed = payeeText.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed != info.payeeName
    }

    var body: some View {
        ReadOnlyDetailContent(
            amount: entry.formattedAmount,
            serviceIcons: [entry.service.systemImage] + (entry.secondaryService.map { [$0.systemImage] } ?? []),
            date: entry.createdAt
        ) {
            Section {
                DraftDetailRow(icon: "text.alignleft", title: entry.service.titleFieldLabel, isEditable: false) {
                    Text(entry.title)
                }
                .cardRowBackground()

                // Only for a Splitwise wallet-automation entry with a still-
                // resolvable merchant mapping — description and payee are the
                // same value at creation time, but the Payee field here edits
                // the merchant's *go-forward* mapping, not this frozen entry.
                if entry.service == .splitwise, let info = linkedInfo {
                    DraftDetailRow(icon: "doc.on.doc", title: "Template", isEditable: false) {
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
                    DraftDetailRow(icon: "tag.fill", title: "Category", isEditable: false) {
                        Text(categoryName)
                    }
                    .cardRowBackground()
                }

                if let accountName = entry.accountName {
                    DraftDetailRow(icon: "creditcard.fill", title: "Account", isEditable: false) {
                        Text(accountName)
                    }
                    .cardRowBackground()
                }
            }

            if let splitSummary = entry.splitSummary {
                Section("Split") {
                    DraftDetailRow(icon: "person.2.fill", title: "With", isEditable: false) {
                        Text(splitSummary)
                    }
                    .cardRowBackground()
                }
            }
        }
        .bottomBarActionButton(isPresented: hasPayeeChanges, title: "Save", action: savePayee)
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
            dismiss()
        } catch {
            logger.error("failed to save edited payee: \(String(describing: error), privacy: .public)")
        }
    }
}

// MARK: - Splitwise expense (read-only, fetched live from Splitwise)

private struct SplitwiseExpenseDetailContent: View {
    let expense: SplitwiseExpense
    let friendName: String
    let onDelete: () async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteError = false

    /// The full cost of the expense (not the signed-in user's share) — no
    /// currency symbol, since the currency is implied by context here.
    /// Falls back to the raw string if it won't parse.
    private var amount: String {
        guard let total = Double(expense.cost) else { return expense.cost }
        return total.asMoneyString
    }

    private var payerDetailLine: (icon: String, text: String)? {
        expense.payerName(friendName: friendName).map { ("creditcard.fill", $0) }
    }

    var body: some View {
        ReadOnlyDetailContent(
            amount: amount,
            serviceIcons: [TransactionService.splitwise.systemImage],
            date: expense.date,
            detailLine: payerDetailLine,
            destroyLabel: "Delete",
            destroyConfirmationTitle: "Delete this expense?",
            onDestroy: delete
        ) {
            Section {
                DraftDetailRow(icon: "text.alignleft", title: "Description", isEditable: false) {
                    Text(expense.description)
                }
                .cardRowBackground()
            }

            Section("Split") {
                ForEach(expense.paidBreakdown(friendName: friendName)) { paid in
                    DraftDetailRow(icon: "creditcard.fill", title: "\(paid.name) paid", isEditable: false) {
                        Text(paid.amount.formatted(.currency(code: expense.currencyCode)))
                    }
                    .cardRowBackground()
                }

                ForEach(expense.shareBreakdown(friendName: friendName)) { share in
                    DraftDetailRow(icon: "person.fill", title: "\(share.name)", isEditable: false) {
                        Text(share.amount.formatted(.currency(code: expense.currencyCode)))
                    }
                    .cardRowBackground()
                }
            }
        }
        .alert("Couldn't Delete", isPresented: $showDeleteError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Please check your connection and try again.")
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

// MARK: - Pending (read-only)

private struct PendingDetailContent: View {
    let operation: PendingOperation

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ReadOnlyDetailContent(
            amount: operation.payload.formattedAmount,
            serviceIcons: [operation.service.systemImage],
            date: operation.queuedAt,
            onDestroy: discard
        ) {
            Section {
                DraftDetailRow(icon: "text.alignleft", title: operation.service.titleFieldLabel, isEditable: false) {
                    Text(operation.payload.title)
                }
                .cardRowBackground()

                if let detail = operation.payload.detail {
                    DraftDetailRow(icon: operation.service == .ynab ? "tag.fill" : "person.2.fill", title: operation.service == .ynab ? "Category" : "With", isEditable: false) {
                        Text(detail)
                    }
                    .cardRowBackground()
                }
            }

            if let lastError = operation.lastError {
                Section("Last Error") {
                    DraftDetailRow(icon: "exclamationmark.triangle.fill", title: "Attempt \(operation.attemptCount)", isEditable: false) {
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
            cleared: "cleared",
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
