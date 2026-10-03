//
//  LedgerDetailView.swift
//  Relay
//
//  The expenses on one ledger, under the balance card ContentView pins. No
//  "Add" in the toolbar: the floating "+" is already scoped to this ledger.
//

import CloudKit
import SwiftUI

struct LedgerDetailView: View {
    let ledger: Ledger

    @State private var store = LedgerStore.shared
    @State private var pendingQueue = PendingOperationQueue.shared
    @State private var sharePresenter = LedgerSharePresenter()
    @State private var selectedExpense: LedgerExpense?
    @State private var showRecordPayment = false
    @State private var renaming: Ledger?
    // Anchored to the row, not the swipe button: iOS 26 animates that wrong,
    // the control being torn down as the swipe closes.
    @State private var expensePendingDelete: LedgerExpense?
    @Namespace private var detailNamespace

    private var current: Ledger { store.current(ledger) }

    private var expenses: [LedgerExpense] { store.expenses(in: current) }

    private var balances: LedgerBalances { store.balances(in: current) }

    var body: some View {
        List {
            Section {
                LedgerBalanceCard(
                    ledger: current,
                    balances: balances,
                    currentUserID: current.currentUserID,
                    lastRefreshedAt: store.lastRefreshedAt,
                    maxWidth: .infinity
                )
                .frame(maxWidth: .infinity)
                .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.backgroundColor)
            }

            if !current.isShared {
                inviteSection
            }

            if !current.pendingInvites.isEmpty {
                pendingInvitesSection
            }

            if expenses.isEmpty {
                if let lastError = store.lastError {
                    Text(lastError)
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(expenses) { expense in
                    Button {
                        selectedExpense = expense
                    } label: {
                        row(for: expense)
                    }
                    .cardRowBackground()
                    .matchedTransitionSource(id: expense.id, in: detailNamespace)
                    .transition(.contentRow)
                    .swipeActions {
                        Button {
                            expensePendingDelete = expense
                        } label: {
                            Image(systemName: Const.Symbol.delete)
                        }
                        .tint(.red)
                    }
                    .confirmationDialog(
                        "Delete this expense?",
                        isPresented: Binding(
                            get: { expensePendingDelete?.id == expense.id },
                            set: { if !$0 { expensePendingDelete = nil } }
                        ),
                        titleVisibility: .visible
                    ) {
                        Button("Delete", role: .destructive) {
                            Task { await store.delete(expense, in: current) }
                        }
                    } message: {
                        Text("This will delete the expense on the ledger for everyone on it.")
                    }
                }
            }
        }
        .themedList(background: .backgroundColor)
        .ledgerRenameAlert($renaming)
        .navigationTitle(current.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .task { await store.refreshExpenses(in: current) }
        .refreshable { await store.refresh(force: true) }
        .sheet(item: $sharePresenter.target) { target in
            LedgerShareSheet(target: target) {
                Task { await store.refresh(force: true) }
            }
        }
        .sheet(item: $selectedExpense) { expense in
            NavigationStack {
                TransactionDetailView(
                    source: .ledgerExpense(
                        expense,
                        ledger: current,
                        onSave: { try await save($0) },
                        onDelete: { await store.delete(expense, in: current) }
                    )
                )
            }
            .navigationTransition(.zoom(sourceID: expense.id, in: detailNamespace))
            .presentationBackground(Color.sheetBackgroundColor)
        }
        .sheet(isPresented: $showRecordPayment) {
            NavigationStack {
                LedgerRecordPaymentView(ledger: current, balances: balances) { settlement in
                    await record(settlement)
                }
            }
            .presentationBackground(Color.sheetBackgroundColor)
        }
    }

    private func row(for expense: LedgerExpense) -> some View {
        TransactionSummaryRow(
            service: .ledger,
            date: expense.date,
            title: expense.title.isEmpty ? String(localized: "Expense") : expense.title,
            amount: amountText(for: expense),
            amountColor: amountColor(for: expense),
            detail: detailText(for: expense),
            isPending: pendingQueue.isPending(expenseID: expense.id)
        )
    }

    /// Negative when the signed-in user owes.
    private func amountText(for expense: LedgerExpense) -> String {
        guard let currentUserID = current.currentUserID else {
            return expense.costCents.asMoneyString
        }
        return expense.netCents(for: currentUserID).asMoneyString
    }

    /// Matches `LedgerBalanceCard`'s headline colour.
    private func amountColor(for expense: LedgerExpense) -> Color? {
        guard let currentUserID = current.currentUserID,
              expense.netCents(for: currentUserID) > 0 else { return nil }
        return Color.accentColor
    }

    /// Who fronted it; a settlement says who paid whom, which a payer and a
    /// cost would read as a purchase.
    private func detailText(for expense: LedgerExpense) -> String? {
        let payerParticipants = expense.payers.compactMap { current.participant(id: $0.participantID) }
        // "You" conjugates differently than a name in German, so it needs its
        // own template rather than substituting into "%@ paid %@".
        let isCurrentUserOnlyPayer = payerParticipants.count == 1 && payerParticipants[0].isCurrentUser
        let payerName = payerParticipants.isEmpty
            ? LedgerParticipant.unknownName
            : ListFormatter.localizedString(byJoining: payerParticipants.map(\.displayName))

        // The row's own amount is the signed-in user's net, not the cost, so
        // the payer's total only shows up here.
        let amount = expense.costCents.asMoneyString

        guard expense.isSettlement,
              let recipient = expense.debtors.first.flatMap({ current.participant(id: $0.participantID) }) else {
            return isCurrentUserOnlyPayer
                ? String(localized: "You paid \(amount)")
                : String(localized: "\(payerName) paid \(amount)")
        }
        return isCurrentUserOnlyPayer
            ? String(localized: "You paid \(recipient.displayName) \(amount)")
            : String(localized: "\(payerName) paid \(recipient.displayName) \(amount)")
    }

    /// Otherwise invisible: they can't be split with.
    private var pendingInvitesSection: some View {
        Section {
            ForEach(current.pendingInvites) { participant in
                HStack {
                    Text(participant.name ?? String(localized: "Someone"))
                    Spacer()
                    Text("Invited")
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            if current.isOwnedByCurrentUser {
                Text("They'll be able to split once they accept. To withdraw an invite, use Manage Sharing.")
                    .footerText()
            }
        }
        .cardRowBackground()
    }

    private var inviteSection: some View {
        Section {
            Text("Only you can see this ledger. Invite someone to start splitting.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button {
                presentShare()
            } label: {
                Label("Invite", systemImage: "person.badge.plus")
            }
            .disabled(!current.isOwnedByCurrentUser || sharePresenter.isPreparing)
        }
        .cardRowBackground()
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button {
                    showRecordPayment = true
                } label: {
                    Label("Record Payment", systemImage: "arrow.left.arrow.right")
                }
                .disabled(!current.isShared)

                Toggle(isOn: Binding(
                    get: { current.simplifiesDebts },
                    set: { simplifies in
                        Task { await store.setSimplifiesDebts(simplifies, in: current) }
                    }
                )) {
                    Label("Simplify Debts", systemImage: "arrow.triangle.merge")
                }

                if current.isOwnedByCurrentUser {
                    Button {
                        presentShare()
                    } label: {
                        Label(current.isShared ? "Manage Sharing" : "Invite", systemImage: "person.badge.plus")
                    }
                }

                NavigationLink(value: ContentRoute.ledgerMembers(zoneName: current.zoneName)) {
                    Label("Members", systemImage: "person.2")
                }

                Button {
                    renaming = current
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
            } label: {
                // Not `ellipsis.circle`: the toolbar draws its own glass.
                Image(systemName: "ellipsis")
            }
        }
    }

    /// `.queued` is not an error: the queue owns the retry.
    private func save(_ expense: LedgerExpense) async throws {
        if await store.save(expense, in: current) == .failed {
            throw LedgerExpenseError.writeFailed(store.lastError)
        }
    }

    /// An expense they owe in full, so the balance falls out unchanged.
    private func record(_ settlement: LedgerSettlement) async {
        await store.save(
            LedgerExpense.settlement(
                from: settlement.from,
                to: settlement.to,
                cents: settlement.cents,
                currencyCode: current.currencyCode
            ),
            in: current
        )
    }

    private func presentShare() { sharePresenter.present(current) }
}
