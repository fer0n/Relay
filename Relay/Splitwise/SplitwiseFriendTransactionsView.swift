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
    @State private var deleteError: String?
    /// Set once `load()` re-fetches the friend list, so the balance card at
    /// the top tracks the same data that refreshes ContentView's own card
    /// rather than staying frozen on the push-time snapshot.
    @State private var refreshedFriend: SplitwiseFriend?
    /// When this friend's expenses were last live-fetched — passed to the
    /// balance card's "Last refreshed …" line, same as ContentView's card.
    @State private var lastRefreshedAt: Date?
    /// Set by the swipe action's "Delete" button to gate a confirmation
    /// before actually deleting — attached to the row itself (not the swipe
    /// button) so the dialog gets the correct appear transition on iOS 26;
    /// anchoring it to a control inside `.swipeActions` animates wrong since
    /// that control is already being torn down as the swipe closes.
    @State private var expensePendingDelete: SplitwiseExpense?
    @Namespace private var detailNamespace

    /// The freshest friend we have: the live-refreshed record if `load()` has
    /// run, otherwise the push-time snapshot.
    private var displayFriend: SplitwiseFriend { refreshedFriend ?? friend }

    var body: some View {
        List {
            Section {
                SplitwiseBalanceCard(friend: displayFriend, lastRefreshedAt: lastRefreshedAt, maxWidth: .infinity)
                    .frame(maxWidth: .infinity)
                    .listRowInsets(
                        .init(
                            top: 0,
                            leading: 0,
                            bottom: 0,
                            trailing: 0
                        )
                    )
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.backgroundColor)
            }

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
                    .matchedTransitionSource(id: expense.id, in: detailNamespace)
                    .transition(.contentRow)
                    .swipeActions {
                        Button {
                            expensePendingDelete = expense
                        } label: {
                            Image(systemName: "trash.fill")
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
                            Task { await deleteWithSwipe(expense) }
                        }
                    }
                }
            }
        }
        .themedList(background: .backgroundColor)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load(force: true) }
        .task {
            withAnimation {
                expenses = SplitwiseExpenseCacheStore.load(friendId: friend.id) ?? []
            }
            lastRefreshedAt = SplitwiseExpenseCacheStore.lastFetchedAt(friendId: friend.id)
            // Navigating away and back recreates this view, re-running
            // `.task`; load(force: false) throttles each fetch on its own
            // cache staleness so that doesn't hit the API on every visit.
            await load(force: false)
        }
        .sheet(item: $selectedExpense) { expense in
            NavigationStack {
                TransactionDetailView(source: .splitwiseExpense(expense, friendName: friend.shortName, onDelete: { try await delete(expense) }))
            }
            .navigationTransition(.zoom(sourceID: expense.id, in: detailNamespace))
            .presentationBackground(Color.sheetBackgroundColor)
        }
        .alert("Couldn't Delete", isPresented: .init(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            if let deleteError {
                Text(deleteError)
            }
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
        let amount = expense.currentUserNetBalance ?? Double(expense.cost)
        return amount?.asMoneyString ?? expense.cost
    }

    /// Accent color when the signed-in user is owed money on this expense (a
    /// positive net balance, "get back"); the default neutral text color
    /// when they owe (negative) or the sign isn't known yet — matches the
    /// balance card's convention (SplitwiseBalanceCard.balanceColor).
    private func amountColor(for expense: SplitwiseExpense) -> Color? {
        guard let net = expense.currentUserNetBalance, net > 0 else { return nil }
        return Color.accentColor
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
        // Backfills SplitwiseCurrentUserStore for accounts signed in before
        // SplitwiseAuthService started warming it on sign-in — without it,
        // currentUserNetBalance can't resolve, so every row falls back to
        // the plain unsigned cost (no sign, no color). Only runs once ever,
        // since the guard is "not cached yet", not a staleness check.
        if SplitwiseCurrentUserStore.load() == nil,
           let user = try? await SplitwiseService.fetchCurrentUser(token: token) {
            try? SplitwiseCurrentUserStore.save(user)
        }
        if force || SplitwiseExpenseCacheStore.isStale(friendId: friend.id) {
            do {
                let fetched = try await SplitwiseExpenseCacheStore.fetch(friendId: friend.id, token: token)
                withAnimation { expenses = fetched }
                lastRefreshedAt = SplitwiseExpenseCacheStore.lastFetchedAt(friendId: friend.id)
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
    /// balance card) doesn't show stale data. Also force-refreshes the
    /// friend's balance right away — deleting an expense changes it, and
    /// waiting on SplitwiseFriendCacheStore's normal staleness window would
    /// leave the balance card showing a stale amount until it happens to
    /// expire.
    private func delete(_ expense: SplitwiseExpense) async throws {
        guard let token = SplitwiseAuthService.currentAccessToken else {
            throw SplitwiseAPIError.unauthorized
        }
        try await SplitwiseService.deleteExpense(id: expense.id, token: token)
        withAnimation { expenses.removeAll { $0.id == expense.id } }
        SplitwiseExpenseCacheStore.save(friendId: friend.id, expenses)
        if let updated = (try? await SplitwiseFriendCacheStore.fetch(token: token))?.first(where: { $0.id == friend.id }) {
            refreshedFriend = updated
        }
    }

    /// Row swipe action's entry point into `delete(_:)` — unlike the sheet's
    /// `onDelete`, a swipe action isn't already inside a `do/catch` showing
    /// its own alert, so this adds that here.
    private func deleteWithSwipe(_ expense: SplitwiseExpense) async {
        do {
            try await delete(expense)
        } catch {
            deleteError = "Please check your connection and try again."
        }
    }
}

#Preview {
    NavigationStack {
        SplitwiseFriendTransactionsView(friend: SplitwiseFriend(id: 1, firstName: "Alex", lastName: nil, balance: nil, picture: nil))
    }
}
