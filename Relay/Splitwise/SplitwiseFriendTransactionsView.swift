//
//  SplitwiseFriendTransactionsView.swift
//  Relay
//
//  Pushed from ContentView's Splitwise balance card — a read-only history of
//  expenses shared with the default friend. Reuses TransactionSummaryRow for
//  each row and TransactionDetailView for the tapped-row detail, same as
//  ContentView's own "Recent" list, instead of hand-rolling either.
//

import SwiftUI

struct SplitwiseFriendTransactionsView: View {
    /// The friend as ContentView had them cached at push time — the source
    /// of truth for identity (id, name) and the initial balance shown before
    /// the first live fetch here.
    let friend: SplitwiseFriend

    @State private var expenses: [SplitwiseExpense] = []
    @State private var loadError: String?
    @State private var selectedExpense: SplitwiseExpense?
    /// Set once `load()` re-fetches the friend list, so the subtitle balance
    /// tracks the same data that refreshes ContentView's balance card rather
    /// than staying frozen on the push-time snapshot.
    @State private var refreshedFriend: SplitwiseFriend?

    /// The freshest friend we have: the live-refreshed record if `load()` has
    /// run, otherwise the push-time snapshot.
    private var displayFriend: SplitwiseFriend { refreshedFriend ?? friend }

    var body: some View {
        List {
            if expenses.isEmpty {
                if let loadError {
                    Text(loadError)
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
                }
            }
        }
        .themedList(background: .backgroundColor)
        .navigationTitle(friend.fullName)
        .navigationSubtitle(Text(displayFriend.formattedBalanceText).foregroundStyle(displayFriend.balanceColor))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load(force: true) }
        .task {
            expenses = SplitwiseExpenseCacheStore.load(friendId: friend.id) ?? []
            // Navigating away and back recreates this view, re-running
            // `.task`; load(force: false) throttles each fetch on its own
            // cache staleness so that doesn't hit the API on every visit.
            await load(force: false)
        }
        .sheet(item: $selectedExpense) { expense in
            NavigationStack {
                TransactionDetailView(source: .splitwiseExpense(expense, friendName: friend.shortName, onDelete: { try await delete(expense) }))
            }
            .presentationBackground(Color.sheetBackgroundColor)
        }
    }

    private func row(for expense: SplitwiseExpense) -> some View {
        TransactionSummaryRow(
            service: .splitwise,
            date: expense.date,
            title: expense.description,
            amount: amountText(for: expense),
            amountColor: amountColor(for: expense),
            detail: expense.payerDescription(friendName: friend.shortName)
        )
    }

    /// The signed share for the current user (e.g. "-12.50" if they owe,
    /// "12.50" if they're owed), falling back to the plain unsigned cost if
    /// the signed-in user's id isn't cached yet.
    private func amountText(for expense: SplitwiseExpense) -> String {
        expense.currentUserNetBalance?.asMoneyString ?? expense.cost
    }

    /// Green when the signed-in user lent money on this expense (a positive
    /// net balance); the default neutral text color when they borrowed
    /// (negative) or the sign isn't known yet — unlike the balance card,
    /// borrowed amounts here aren't flagged red.
    private func amountColor(for expense: SplitwiseExpense) -> Color? {
        guard let net = expense.currentUserNetBalance, net > 0 else { return nil }
        return .green
    }

    /// Refreshes the expense list and the friend balance, each throttled on
    /// its own cache's staleness unless `force` (pull-to-refresh) bypasses it.
    /// Gating them independently means arriving from ContentView /
    /// SplitwiseBalancesView — which may have just refreshed the friend list —
    /// doesn't redundantly re-fetch it, and a fresh expense cache doesn't
    /// block refreshing a stale balance (or vice versa).
    private func load(force: Bool) async {
        guard let token = SplitwiseAuthService.currentAccessToken else {
            loadError = "Not connected to Splitwise."
            return
        }
        if force || SplitwiseExpenseCacheStore.isStale(friendId: friend.id) {
            do {
                expenses = try await SplitwiseExpenseCacheStore.fetch(friendId: friend.id, token: token)
                loadError = nil
            } catch {
                loadError = "Couldn't load transactions."
            }
        }
        // The friend fetch refreshes the same SplitwiseFriendCacheStore that
        // backs ContentView's balance card, so popping back shows an
        // up-to-date balance (reloadMainListState re-reads that cache on pop).
        // Non-fatal — the expense list is what this view is for, so only an
        // expense failure surfaces an error above.
        if force || SplitwiseFriendCacheStore.isStale,
           let updated = (try? await SplitwiseFriendCacheStore.fetch(token: token))?.first(where: { $0.id == friend.id }) {
            refreshedFriend = updated
        }
    }

    /// Deletes `expense` on Splitwise, then drops it from the in-memory list
    /// and re-saves the cache so popping back to this list (or ContentView's
    /// balance card) doesn't show stale data. Leaves the friend's cached
    /// balance to the next live refresh rather than recomputing it locally.
    private func delete(_ expense: SplitwiseExpense) async throws {
        guard let token = SplitwiseAuthService.currentAccessToken else {
            throw SplitwiseAPIError.unauthorized
        }
        try await SplitwiseService.deleteExpense(id: expense.id, token: token)
        expenses.removeAll { $0.id == expense.id }
        SplitwiseExpenseCacheStore.save(friendId: friend.id, expenses)
    }
}

#Preview {
    NavigationStack {
        SplitwiseFriendTransactionsView(friend: SplitwiseFriend(id: 1, firstName: "Alex", lastName: nil, balance: nil))
    }
}
