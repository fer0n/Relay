//
//  SplitwiseBalancesView.swift
//  Relay
//
//  Pushed from ContentView's "Balances" row — a 2-up grid of every friend and
//  group with an outstanding Splitwise balance, each card the same
//  SplitwiseBalanceCard shown for the default friend on ContentView. Tapping
//  a card pushes SplitwiseTransactionsView — a friend's history or a group's —
//  same as the default friend's card, so every entry point shares the same
//  list/detail/refresh behavior for free.
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
    @State private var groups: [SplitwiseGroup] = Self.outstandingGroups(SplitwiseGroupCacheStore.load())
    @State private var lastRefreshedAt = SplitwiseFriendCacheStore.lastFetchedAt

    private static var currentUserId: Int? { SplitwiseCurrentUserStore.load()?.id }

    /// Everything the signed-in user is up or down, as a title subheader.
    ///
    /// Summed over friends only, deliberately: `get_friends` reports the net
    /// balance with each friend across *all* groups, so adding the group cards'
    /// figures on top would count group debts twice. Nil while nothing is
    /// cached, and formatted in the first currency seen — the same
    /// one-currency assumption `SplitwiseFriend.primaryBalance` makes.
    private var totalBalance: (amount: Double, currencyCode: String)? {
        let balances = friends.compactMap(\.primaryBalance)
        guard let currencyCode = balances.first?.currencyCode else { return nil }
        return (balances.reduce(0) { $0 + $1.amount }, currencyCode)
    }

    /// Only groups the signed-in user is actually up or down in — a settled
    /// group is as uninteresting here as a settled friend.
    private static func outstandingGroups(_ groups: [SplitwiseGroup]?) -> [SplitwiseGroup] {
        (groups ?? []).filter { $0.hasOutstandingBalance(currentUserId: currentUserId) }
    }

    static let spacing: CGFloat = 10

    private let columns = [GridItem(.flexible(), spacing: spacing), GridItem(.flexible(), spacing: spacing)]

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 16) {
                    LazyVGrid(columns: columns, spacing: SplitwiseBalancesView.spacing) {
                        ForEach(friends, id: \.id) { friend in
                            NavigationLink(value: ContentRoute.splitwiseFriendTransactions(friendId: friend.id)) {
                                SplitwiseBalanceCard(friend: friend, size: .compact, maxWidth: .infinity)
                            }
                            .buttonStyle(.plain)
                        }
                        ForEach(groups, id: \.id) { group in
                            NavigationLink(value: ContentRoute.splitwiseGroupTransactions(groupId: group.id)) {
                                SplitwiseBalanceCard(
                                    group: group,
                                    currentUserId: Self.currentUserId,
                                    size: .compact,
                                    maxWidth: .infinity
                                )
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
            if friends.isEmpty, groups.isEmpty {
                EmptyListBackground(systemName: "person.2")
            }
        }
        .navigationTitle("Balances")
        // Coloured like every other balance in the app, and an empty subtitle
        // renders as none — which is what "nothing cached yet" should look like.
        .navigationSubtitle(
            totalBalance.map {
                Text($0.amount.formatted(.currency(code: $0.currencyCode)))
                    .foregroundStyle(Color.splitwiseBalance($0.amount))
            } ?? Text(verbatim: "")
        )
        .refreshable { await refresh(force: true) }
        // Same throttle-unless-forced pattern as ContentView's
        // refreshDefaultSplitwiseFriend — re-running `.task` on every
        // navigation back to this screen shouldn't hit the API if the cache
        // is still fresh.
        .task { await refresh(force: false) }
    }

    private func refresh(force: Bool) async {
        // Re-seed from disk first. This view's `@State` is seeded once, when it's
        // first constructed, and its cache can be refreshed from anywhere else
        // in the app — a friend's or group's own page, a shortcut — after which
        // the fetches below are throttled off as "fresh" and the grid would
        // otherwise keep rendering the snapshot it started with.
        if let cached = SplitwiseFriendCacheStore.load() {
            friends = cached.partitionedByBalance.outstanding
            lastRefreshedAt = SplitwiseFriendCacheStore.lastFetchedAt
        }
        groups = Self.outstandingGroups(SplitwiseGroupCacheStore.load())

        guard let token = SplitwiseAuthService.currentAccessToken else { return }
        if force || SplitwiseFriendCacheStore.isStale,
           let fetched = try? await SplitwiseFriendCacheStore.fetch(token: token) {
            friends = fetched.partitionedByBalance.outstanding
            lastRefreshedAt = SplitwiseFriendCacheStore.lastFetchedAt
        }
        if force || SplitwiseGroupCacheStore.isStale,
           let fetched = try? await SplitwiseGroupCacheStore.fetch(token: token) {
            groups = Self.outstandingGroups(fetched)
        }
        // A group's balance is read off the signed-in user's own member entry,
        // so without their id every group looks settled.
        if Self.currentUserId == nil, let user = try? await SplitwiseService.fetchCurrentUser(token: token) {
            try? SplitwiseCurrentUserStore.save(user)
            groups = Self.outstandingGroups(SplitwiseGroupCacheStore.load())
        }
    }
}

#Preview {
    let friend1 = SplitwiseFriend(id: 1, firstName: "Alex", lastName: "Kim", balance: [SplitwiseBalance(currencyCode: Const.currencyCode, amount: "42.50")], picture: nil)
    let friend2 = SplitwiseFriend(id: 2, firstName: "Sam", lastName: nil, balance: [SplitwiseBalance(currencyCode: Const.currencyCode, amount: "-12.00")], picture: nil)
    SplitwiseFriendCacheStore.save([friend1, friend2])
    // A group's card reads its balance off the signed-in user's own member
    // entry, so the preview needs both stores populated.
    try? SplitwiseCurrentUserStore.save(SplitwiseUser(id: 99, firstName: "You"))
    SplitwiseGroupCacheStore.save([
        SplitwiseGroup(
            id: 7,
            name: "Flat",
            members: [
                SplitwiseGroupMember(id: 99, firstName: "You", lastName: nil, picture: nil, balance: [SplitwiseBalance(currencyCode: Const.currencyCode, amount: "-31.75")]),
                SplitwiseGroupMember(id: 1, firstName: "Alex", lastName: "Kim", picture: nil, balance: nil),
            ],
            avatar: nil
        )
    ])
    return NavigationStack {
        SplitwiseBalancesView()
            .navigationDestination(for: ContentRoute.self) { route in
                switch route {
                case .splitwiseFriendTransactions(let friendId):
                    if let friend = SplitwiseFriendCacheStore.load()?.first(where: { $0.id == friendId }) {
                        SplitwiseTransactionsView(friend: friend)
                    }
                case .splitwiseGroupTransactions(let groupId):
                    if let group = SplitwiseGroupCacheStore.load()?.first(where: { $0.id == groupId }) {
                        SplitwiseTransactionsView(group: group)
                    }
                default:
                    EmptyView()
                }
            }
    }
}
