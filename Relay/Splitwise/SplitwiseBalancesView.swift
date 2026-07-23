//
//  SplitwiseBalancesView.swift
//  Relay
//
//  Pushed from ContentView's "Balances" row — a 2-up grid of every friend
//  with an outstanding Splitwise balance, each card the same
//  SplitwiseBalanceCard shown for the default friend on ContentView. Tapping
//  a card pushes SplitwiseFriendTransactionsView, same as the default
//  friend's card, so both entry points share the same list/detail/refresh
//  behavior for free.
//
//  A plain ScrollView, not a List — List's row/selection machinery expects
//  one tap target per row, and nesting several NavigationLinks side by side
//  inside a single List row (the LazyVGrid) misfires navigation. A grid of
//  NavigationLinks belongs in a ScrollView instead.
//

import Combine
import SwiftUI

struct SplitwiseBalancesView: View {
    @State private var friends = SplitwiseFriendCacheStore.load()?.partitionedByBalance.outstanding ?? []
    @State private var lastRefreshedAt = SplitwiseFriendCacheStore.lastFetchedAt
    /// Advanced by `clock` so `lastRefreshedSubtitle` re-renders live.
    /// `navigationSubtitle` takes only a `Text` (which can't embed the balance
    /// card's TimelineView), so the tick has to come from state here.
    @State private var now = Date()

    static let spacing: CGFloat = 10

    private let columns = [GridItem(.flexible(), spacing: spacing), GridItem(.flexible(), spacing: spacing)]
    /// A coarse 60s tick, not per-second: the subtitle is fuzzy (whole minutes
    /// past the first minute), so a minute cadence keeps it roughly current
    /// without re-rendering the screen every second.
    private let clock = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: SplitwiseBalancesView.spacing) {
                ForEach(friends, id: \.id) { friend in
                    NavigationLink {
                        SplitwiseFriendTransactionsView(friend: friend)
                    } label: {
                        SplitwiseBalanceCard(friend: friend, size: .compact, maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .background {
            Color.backgroundColor
            if friends.isEmpty {
                EmptyListBackground(systemName: "person.2")
            }
        }
        .navigationTitle("Balances")
        .navigationSubtitle(lastRefreshedSubtitle)
        .refreshable { await refresh(force: true) }
        // Same throttle-unless-forced pattern as ContentView's
        // refreshDefaultSplitwiseFriend — re-running `.task` on every
        // navigation back to this screen shouldn't hit the API if the cache
        // is still fresh.
        .task { await refresh(force: false) }
        .onReceive(clock) { now = $0 }
    }

    /// Live, single-unit "x min ago" in the nav sub header, replacing the old
    /// verbose "Last refreshed …" that was computed once per render (so it
    /// stayed frozen between refreshes). `navigationSubtitle` only accepts a
    /// `Text`, so — unlike the balance card's embedded TimelineView — this
    /// recomputes from `now` (ticked by `clock`); `fuzzyRelative` is coarse,
    /// so the text only changes on a unit step, and `Text.monospacedDigit()`
    /// keeps the width from jumping.
    private var lastRefreshedSubtitle: Text {
        guard let lastRefreshedAt else { return Text("") }
        return Text(lastRefreshedAt.fuzzyRelative(to: now)).monospacedDigit()
    }

    private func refresh(force: Bool) async {
        guard force || SplitwiseFriendCacheStore.isStale else { return }
        guard let token = SplitwiseAuthService.currentAccessToken else { return }
        if let fetched = try? await SplitwiseFriendCacheStore.fetch(token: token) {
            friends = fetched.partitionedByBalance.outstanding
            lastRefreshedAt = SplitwiseFriendCacheStore.lastFetchedAt
        }
    }
}

#Preview {
    let friend1 = SplitwiseFriend(id: 1, firstName: "Alex", lastName: "Kim", balance: [SplitwiseBalance(currencyCode: "EUR", amount: "42.50")])
    let friend2 = SplitwiseFriend(id: 2, firstName: "Sam", lastName: nil, balance: [SplitwiseBalance(currencyCode: "EUR", amount: "-12.00")])
    SplitwiseFriendCacheStore.save([friend1, friend2])
    return NavigationStack {
        SplitwiseBalancesView()
    }
}
