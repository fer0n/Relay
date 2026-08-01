//
//  SplitwiseFriendTransactionsView.swift
//  Relay
//
//  Pushed from ContentView's Splitwise balance card — the history of expenses
//  shared with one friend, reusing the same row/detail views as ContentView's
//  own "Recent" list.
//

import SwiftUI

struct SplitwiseFriendTransactionsView: View {
    /// Cached at push time — the source of truth for identity, and the balance
    /// shown before the first live fetch here.
    let friend: SplitwiseFriend

    @State private var expenses: [SplitwiseExpense] = []
    @State private var loadError: String?
    @State private var selectedExpense: SplitwiseExpense?
    @State private var deleteError: String?
    /// Set once `load()` re-fetches, so the balance card doesn't stay frozen on
    /// the push-time snapshot.
    @State private var refreshedFriend: SplitwiseFriend?
    /// Feeds the balance card's "Last refreshed …" line.
    @State private var lastRefreshedAt: Date?
    /// The confirmation dialog is attached to the row itself, not the swipe
    /// button: on iOS 26 a dialog anchored to a control inside `.swipeActions`
    /// animates wrong, since that control is torn down as the swipe closes.
    @State private var expensePendingDelete: SplitwiseExpense?
    @Namespace private var detailNamespace

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
                            Task { await deleteWithSwipe(expense) }
                        }
                    } message: {
                        Text("This will delete the expense on Splitwise for everyone involved.")
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
            // Navigating away and back re-runs this `.task`; load(force: false)
            // throttles on cache staleness so that doesn't hit the API each time.
            await load(force: false)
        }
        .sheet(item: $selectedExpense) { expense in
            NavigationStack {
                TransactionDetailView(
                    source: .splitwiseExpense(
                        expense,
                        friendName: friend.shortName,
                        onSave: { try await update(expense, with: $0) },
                        onDelete: { try await delete(expense) }
                    )
                )
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

    /// Negative when the signed-in user owes. Falls back to the plain unsigned
    /// cost when their id isn't cached yet.
    private func amountText(for expense: SplitwiseExpense) -> String {
        let amount = expense.currentUserNetBalance ?? Double(expense.cost)
        return amount?.asMoneyString ?? expense.cost
    }

    /// Accent when the signed-in user is owed, neutral otherwise — matching
    /// `SplitwiseBalanceCard.balanceColor`.
    private func amountColor(for expense: SplitwiseExpense) -> Color? {
        guard let net = expense.currentUserNetBalance, net > 0 else { return nil }
        return Color.accentColor
    }

    /// Refreshes the expense list and the friend balance, each throttled on its
    /// own cache's staleness unless `force`. Gating them independently means
    /// arriving from a screen that just refreshed the friend list doesn't re-fetch
    /// it, and a fresh cache on one side doesn't block the other.
    private func load(force: Bool) async {
        guard let token = SplitwiseAuthService.currentAccessToken else {
            loadError = "Not connected to Splitwise."
            return
        }
        // Backfills SplitwiseCurrentUserStore for accounts signed in before
        // sign-in started warming it — without it every row falls back to the
        // plain unsigned cost. Runs once ever: the guard is "not cached yet".
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
        // Refreshes the same cache backing ContentView's balance card, so popping
        // back shows an up-to-date balance. Non-fatal: the expense list is what
        // this view is for, so only an expense failure surfaces an error.
        if force || SplitwiseFriendCacheStore.isStale,
           let updated = (try? await SplitwiseFriendCacheStore.fetch(token: token))?.first(where: { $0.id == friend.id }) {
            refreshedFriend = updated
        }
    }

    /// Writes the saved version back into the list and cache so both reflect it
    /// straight away rather than after the next staleness window. The detail sheet
    /// builds the request and surfaces any error this throws.
    private func update(_ expense: SplitwiseExpense, with request: SplitwiseExpenseUpdateRequest) async throws {
        guard let token = SplitwiseAuthService.currentAccessToken else {
            throw SplitwiseAPIError.unauthorized
        }
        let saved = try await SplitwiseService.updateExpense(id: expense.id, request, token: token)
        if let saved {
            withAnimation {
                if let index = expenses.firstIndex(where: { $0.id == expense.id }) {
                    expenses[index] = saved
                }
            }
            SplitwiseExpenseCacheStore.save(friendId: friend.id, expenses)
        } else if let refetched = try? await SplitwiseExpenseCacheStore.fetch(friendId: friend.id, token: token) {
            // Saved, but Splitwise didn't hand back the stored expense — re-fetch
            // rather than leave the row on pre-edit values.
            withAnimation { expenses = refetched }
            lastRefreshedAt = SplitwiseExpenseCacheStore.lastFetchedAt(friendId: friend.id)
        }
        if let updated = (try? await SplitwiseFriendCacheStore.fetch(token: token))?.first(where: { $0.id == friend.id }) {
            refreshedFriend = updated
        }
    }

    /// Force-refreshes the friend's balance right away, since a deletion changes
    /// it and the normal staleness window would leave the balance card stale.
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

    /// A swipe action isn't already inside a `do/catch` showing its own alert, as
    /// the sheet's `onDelete` is, so this adds one.
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
