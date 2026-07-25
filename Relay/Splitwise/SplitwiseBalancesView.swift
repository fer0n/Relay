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

    static let spacing: CGFloat = 10

    private let columns = [GridItem(.flexible(), spacing: spacing), GridItem(.flexible(), spacing: spacing)]

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 16) {
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

                    Spacer(minLength: 16)

                    if let lastRefreshedAt {
                        FuzzyDateText(date: lastRefreshedAt)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding()
                .frame(minHeight: geometry.size.height)
            }
        }
        .background {
            Color.backgroundColor
            if friends.isEmpty {
                EmptyListBackground(systemName: "person.2")
            }
        }
        .navigationTitle("Balances")
        .refreshable { await refresh(force: true) }
        // Same throttle-unless-forced pattern as ContentView's
        // refreshDefaultSplitwiseFriend — re-running `.task` on every
        // navigation back to this screen shouldn't hit the API if the cache
        // is still fresh.
        .task { await refresh(force: false) }
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
    let friend1 = SplitwiseFriend(id: 1, firstName: "Alex", lastName: "Kim", balance: [SplitwiseBalance(currencyCode: "EUR", amount: "42.50")], picture: nil)
    let friend2 = SplitwiseFriend(id: 2, firstName: "Sam", lastName: nil, balance: [SplitwiseBalance(currencyCode: "EUR", amount: "-12.00")], picture: nil)
    SplitwiseFriendCacheStore.save([friend1, friend2])
    return NavigationStack {
        SplitwiseBalancesView()
    }
}
